# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Embeddings
  API_URL = "https://ai.hackclub.com/proxy/v1/embeddings"
  MODEL = ENV.fetch("EMBED_MODEL", "qwen/qwen3-embedding-8b")

  # Embed a single string or a batch (array of strings).
  # Returns a single Array<Float> for a string, or Array<Array<Float>> for a batch.
  def self.embed(input)
    is_batch = input.is_a?(Array)

    uri = URI(API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 120

    req = Net::HTTP::Post.new(uri.path)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"] = "application/json"
    req.body = { model: MODEL, input: input }.to_json

    resp = http.request(req)
    raise "Embedding API error #{resp.code}: #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

    data = JSON.parse(resp.body)
    embeddings = data["data"].sort_by { |d| d["index"] }.map { |d| d["embedding"] }
    is_batch ? embeddings : embeddings.first
  end

  def self.api_key
    ENV.fetch("HACKCLUB_AI_API_KEY") { raise "HACKCLUB_AI_API_KEY environment variable not set" }
  end
end
