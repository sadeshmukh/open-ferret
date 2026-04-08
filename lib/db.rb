# frozen_string_literal: true

require "sqlite3"
require "sqlite_vec"

module DB
  DB_PATH = File.expand_path("../../data/ferret.db", __FILE__)
  EMBED_DIM = ENV.fetch("EMBED_DIM", "4096").to_i # qwen/qwen3-embedding-8b default

  def self.connection
    @db ||= begin
      db = SQLite3::Database.new(DB_PATH)
      db.results_as_hash = true
      db.execute("PRAGMA journal_mode=WAL")
      db.execute("PRAGMA synchronous=NORMAL")
      db.enable_load_extension(true)
      SqliteVec.load(db)
      db.enable_load_extension(false)
      migrate(db)
      db
    end
  end

  def self.migrate(db)
    db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS projects (
        record_id TEXT PRIMARY KEY,
        description TEXT,
        description_clean TEXT,
        playable_url TEXT,
        code_url TEXT,
        hours_spent REAL,
        name TEXT,
        country TEXT,
        ysws_name TEXT,
        github_username TEXT,
        screenshot_url TEXT,
        github_stars INTEGER DEFAULT 0,
        approved_at INTEGER,
        archived_demo TEXT,
        archived_repo TEXT,
        updated_at TEXT DEFAULT (datetime('now'))
      )
    SQL

    db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS vec_lookup (
        rowid INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id TEXT NOT NULL UNIQUE REFERENCES projects(record_id)
      )
    SQL

    db.execute(<<~SQL)
      CREATE VIRTUAL TABLE IF NOT EXISTS vec_projects USING vec0(
        rowid INTEGER PRIMARY KEY,
        embedding float[#{EMBED_DIM}]
      )
    SQL

    db.execute(<<~SQL)
      CREATE VIRTUAL TABLE IF NOT EXISTS fts_projects USING fts5(
        record_id UNINDEXED,
        description_clean,
        content='',
        tokenize='porter unicode61'
      )
    SQL
  end

  # strip markdown, urls, extra whitespace
  def self.clean(text)
    return nil if text.nil?

    text = text.gsub(%r{https?://\S+}, "")
    text = text.gsub(/[#*_`~\[\]()>|]/, "")
    text.gsub(/\s+/, " ").strip
  end
end
