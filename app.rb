# frozen_string_literal: true

require "sinatra"
require "json"
require "digest"
require "lru_redux"
require_relative "lib/db"
require_relative "lib/embeddings"

if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]
  require "opentelemetry/sdk"
  require "opentelemetry/exporter/otlp"
  require "opentelemetry/instrumentation/sinatra"

  OpenTelemetry::SDK.configure do |c|
    c.service_name = "open-ferret"
    c.use "OpenTelemetry::Instrumentation::Sinatra"
  end

  TRACER = OpenTelemetry.tracer_provider.tracer("open-ferret")
else
  TRACER = Module.new do
    def self.in_span(*, **)
      yield
    end
  end
end

set :port, 4567
set :bind, "0.0.0.0"
set :public_folder, File.join(__dir__, "public")
set :host_authorization, permitted_hosts: ENV["APP_HOST"] ? [ENV["APP_HOST"]] : []

# RRF weights — vector search gets 2x weight over FTS
VEC_WEIGHT = 2.0
FTS_WEIGHT = 1.0
RRF_K = 60.0

# candidate pool for retrieval before final ordering
RERANK_POOL = 37

# short descriptions are noisier — discount scores for descriptions under this length
DESC_LEN_THRESHOLD = 100

# LRU cache
CACHE = LruRedux::TTL::ThreadSafeCache.new(256, 5 * 60)
CACHE_TTL = 300

# simple query expansion: add OR'd synonyms for common search intents
EXPANSIONS = {
  "game" => "game games gaming",
  "art" => "art artistic creative visual",
  "music" => "music musical audio sound",
  "draw" => "draw drawing paint painting",
  "web" => "web website webapp",
  "ai" => "ai artificial intelligence ml machine learning",
  "3d" => "3d three dimensional",
  "chat" => "chat messaging conversation"
}.freeze

def expand_fts_query(query)
  words = query.downcase.split(/\s+/)
  parts = words.map do |w|
    expanded = EXPANSIONS[w]
    if expanded
      "(#{expanded.split.map { |s| %("#{s}") }.join(' OR ')})"
    else
      %("#{w}")
    end
  end
  parts.join(" ")
end

get "/" do
  erb :index
end

get "/ysws_names.json" do
  content_type :json
  db = DB.connection
  rows = db.execute("SELECT DISTINCT ysws_name FROM projects WHERE ysws_name IS NOT NULL ORDER BY ysws_name")
  rows.map { |r| r["ysws_name"] }.to_json
end

get "/search.json" do
  content_type :json
  cache_key = params.sort_by { |k, _| k }.map { |k, v| "#{k}=#{v}" }.join("&")
  cached = CACHE[cache_key]
  if cached
    cache_control :public, max_age: CACHE_TTL
    etag Digest::MD5.hexdigest(cached)
    return cached
  end

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  raw_q = params[:q]&.strip
  limit = params[:limit]&.to_i
  limit = limit&.positive? ? limit.clamp(1, 1000) : 20

  # parse -word exclusions (only at word boundary, so "orpheus-engine" is safe)
  exclude_terms = []
  q = raw_q&.gsub(/(?:^|\s)-(\S+)/) { exclude_terms << $1; "" }&.strip
  db = DB.connection

  # --- build filter clauses (shared by both paths) ---
  where_clauses = []
  filter_params = []

  if params[:country] && !params[:country].empty?
    c = params[:country].strip
    if c.length <= 2
      where_clauses << "country = ? COLLATE NOCASE"
      filter_params << c
    else
      where_clauses << "country LIKE ? COLLATE NOCASE"
      filter_params << "%#{c}%"
    end
  end
  if params[:min_hours] && !params[:min_hours].empty?
    where_clauses << "hours_spent >= ?"
    filter_params << params[:min_hours].to_f
  end
  if params[:exclude_zero_hours] == "1"
    where_clauses << "hours_spent > 0"
  end
  ysws_include = Array(params[:ysws_name]).reject(&:empty?)
  unless ysws_include.empty?
    ysws_ph = ysws_include.map { "?" }.join(", ")
    where_clauses << "ysws_name IN (#{ysws_ph})"
    filter_params.concat(ysws_include)
  end
  ysws_exclude = Array(params[:ysws_exclude]).reject(&:empty?)
  unless ysws_exclude.empty?
    ysws_ph = ysws_exclude.map { "?" }.join(", ")
    where_clauses << "ysws_name NOT IN (#{ysws_ph})"
    filter_params.concat(ysws_exclude)
  end

  filter_where = where_clauses.empty? ? "" : "WHERE #{where_clauses.join(' AND ')}"

  # --- no query: filter-only browse (possibly with -exclusions) ---
  if q.nil? || q.empty?
    # fetch extra to account for exclusion filtering
    fetch_limit = exclude_terms.empty? ? limit : limit * 3
    projects = db.execute(<<~SQL, filter_params + [fetch_limit])
      SELECT record_id, description_clean, playable_url, code_url,
             hours_spent, name, country, ysws_name, github_username,
             github_stars, approved_at, archived_demo, archived_repo
      FROM projects
      #{filter_where}
      ORDER BY hours_spent DESC
      LIMIT ?
    SQL

    unless exclude_terms.empty?
      patterns = exclude_terms.map { |t| /\b#{Regexp.escape(t)}\b/i }
      projects.reject! { |p| patterns.any? { |pat| p["description_clean"]&.match?(pat) } }
      projects = projects.first(limit)
    end

    ysws_counts = projects.each_with_object(Hash.new(0)) { |p, h| h[p["ysws_name"]] += 1 if p["ysws_name"] }
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    result = { results: projects, query: "", ysws_counts: ysws_counts, ms: ms }.to_json
    CACHE[cache_key] = result
    cache_control :public, max_age: CACHE_TTL
    etag Digest::MD5.hexdigest(result)
    return result
  end

  timings = {}
  pool = [RERANK_POOL, limit * 2].max
  use_vec = params[:use_vec] != "0"
  use_fts = params[:use_fts] != "0"

  # --- vector search ---
  vec_results = []
  if use_vec
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    embedding = TRACER.in_span("embed") do
      Embeddings.embed(q)
    end
    timings[:embed] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    blob = embedding.pack("e*")
    TRACER.in_span("vec_knn", attributes: { "k" => pool }) do
      vec_results = db.execute(<<~SQL, [blob, pool])
        SELECT v.record_id, vp.distance
        FROM (
          SELECT rowid, distance
          FROM vec_projects
          WHERE embedding MATCH ? AND k = ?
        ) vp
        JOIN vec_lookup v ON v.rowid = vp.rowid
      SQL
    end
    timings[:vec_knn] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round
  end

  # --- fts search with query expansion ---
  fts_results = []
  if use_fts
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    fts_query = expand_fts_query(q)
    fts_results = TRACER.in_span("fts") do
      begin
        db.execute(<<~SQL, [fts_query, pool])
          SELECT v.record_id, fts.rank
          FROM fts_projects fts
          JOIN vec_lookup v ON v.rowid = fts.rowid
          WHERE fts_projects MATCH ?
          ORDER BY fts.rank
          LIMIT ?
        SQL
      rescue SQLite3::SQLException
        []
      end
    end
    timings[:fts] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round
  end

  # --- weighted RRF fusion ---
  scores = Hash.new(0.0)

  vec_results.each_with_index do |r, i|
    scores[r["record_id"]] += VEC_WEIGHT / (RRF_K + i + 1)
  end

  fts_results.each_with_index do |r, i|
    scores[r["record_id"]] += FTS_WEIGHT / (RRF_K + i + 1)
  end

  candidate_ids = scores.sort_by { |_, s| -s }.first(pool).map(&:first)
  return { results: [], query: q, ysws_names: [] }.to_json if candidate_ids.empty?

  # --- fetch candidate projects ---
  placeholders = candidate_ids.map { "?" }.join(", ")
  id_where = "record_id IN (#{placeholders})"
  extra = where_clauses.empty? ? "" : " AND #{where_clauses.join(' AND ')}"

  candidates = db.execute(<<~SQL, candidate_ids + filter_params)
    SELECT record_id, description_clean, playable_url, code_url,
           hours_spent, name, country, ysws_name, github_username,
           github_stars, approved_at, archived_demo, archived_repo
    FROM projects
    WHERE #{id_where}#{extra}
  SQL

  return { results: [], query: q, ysws_names: [] }.to_json if candidates.empty?

  # --- order by RRF score, apply description length discount ---
  ordered = candidates.map do |c|
    score = scores[c["record_id"]] || 0.0
    desc_len = (c["description_clean"] || "").length
    score *= (desc_len.to_f / DESC_LEN_THRESHOLD) if desc_len < DESC_LEN_THRESHOLD
    proj = c.dup
    proj["score"] = score.round(4)
    proj
  end.sort_by { |p| -p["score"] }

  # apply -word exclusions with word boundary matching
  unless exclude_terms.empty?
    patterns = exclude_terms.map { |t| /\b#{Regexp.escape(t)}\b/i }
    ordered.reject! { |p| patterns.any? { |pat| p["description_clean"]&.match?(pat) } }
  end

  ordered = ordered.first(limit)
  ysws_counts = ordered.each_with_object(Hash.new(0)) { |p, h| h[p["ysws_name"]] += 1 if p["ysws_name"] }
  ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
  timings[:total] = ms
  if defined?(OpenTelemetry)
    span = OpenTelemetry::Trace.current_span
    span.set_attribute("search.query", q)
    span.set_attribute("search.results_count", ordered.length)
    span.set_attribute("search.ms", ms)
  end

  result = { results: ordered, query: q, ysws_counts: ysws_counts, ms: ms, timings: timings }.to_json
  CACHE[cache_key] = result
  cache_control :public, max_age: CACHE_TTL
  etag Digest::MD5.hexdigest(result)
  result
end
