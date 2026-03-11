#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "dotenv/load"
require "net/http"
require "json"
require "uri"
require "fileutils"
require "optparse"
require "time"
require "digest"
require "open-uri"

BASE_URL = "https://api.app.shortcut.com/api/v3"
MEDIA_HOST = "media.app.shortcut.com"
OUTPUT_DIR = ENV.fetch("OUTPUT_DIR", "/export")

class ShortcutClient
  attr_reader :token

  def initialize(token)
    @token = token
    @request_count = 0
    @window_start = Time.now
  end

  def get(path, params = {})
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params) unless params.empty?
    request = Net::HTTP::Get.new(uri)
    execute(request, uri)
  end

  def post(path, body = {})
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Post.new(uri)
    request.body = body.to_json
    execute(request, uri)
  end

  private

  def execute(request, uri)
    throttle!

    request["Content-Type"] = "application/json"
    request["Shortcut-Token"] = @token

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    case response.code.to_i
    when 200, 201
      JSON.parse(response.body)
    when 204
      nil
    when 429
      wait = (response["Retry-After"] || 60).to_i
      warn "Rate limited. Waiting #{wait}s..."
      sleep(wait)
      execute(request, uri)
    else
      warn "API error #{response.code} on #{uri.path}: #{response.body}"
      nil
    end
  end

  def throttle!
    @request_count += 1
    elapsed = Time.now - @window_start

    if elapsed >= 60
      @request_count = 1
      @window_start = Time.now
      return
    end

    return unless @request_count >= 190

    wait = 60 - elapsed + 1
    warn "Approaching rate limit, pausing #{wait.round}s..."
    sleep(wait)
    @request_count = 0
    @window_start = Time.now
  end
end

class MarkdownExporter
  def initialize(client, output_dir)
    @client = client
    @output_dir = output_dir
    @members_cache = {}
    @workflows_cache = {}
    @epic_states_cache = {}
  end

  def export_epic(epic_id)
    puts "Fetching epic ##{epic_id}..."
    epic = @client.get("/epics/#{epic_id}")
    return warn("Epic ##{epic_id} not found.") unless epic

    write_epic(epic)

    puts "Fetching stories for epic ##{epic_id}..."
    stories_slim = @client.get("/epics/#{epic_id}/stories")
    if stories_slim
      stories = fetch_full_stories(stories_slim)
      stories.each { |story| write_story(story) }
      export_files_from_stories(stories)
      puts "Exported #{stories.size} stories from epic '#{epic["name"]}'."
    end

    puts "Fetching comments for epic ##{epic_id}..."
    comments = @client.get("/epics/#{epic_id}/comments")
    write_epic_comments(epic, comments) if comments&.any?
  end

  def export_team(team_name)
    puts "Looking up team '#{team_name}'..."
    groups = @client.get("/groups")
    return warn("Could not fetch groups.") unless groups

    group = groups.find { |g| g["name"].downcase == team_name.downcase }
    return warn("Team '#{team_name}' not found. Available: #{groups.map { |g| g["name"] }.join(", ")}") unless group

    group_id = group["id"]
    puts "Found team '#{group["name"]}' (#{group_id}). Searching stories..."

    all_stories = []
    next_token = nil

    loop do
      body = { "group_ids" => [group_id], "page_size" => 25 }
      body["next"] = next_token if next_token

      result = @client.post("/stories/search", body)
      break unless result

      stories = result["data"] || result
      all_stories.concat(stories) if stories.is_a?(Array)

      next_token = result["next"]
      break unless next_token
    end

    puts "Found #{all_stories.size} stories for team '#{group["name"]}'. Fetching full details..."
    all_stories = fetch_full_stories(all_stories)
    all_stories.each { |story| write_story(story) }
    export_files_from_stories(all_stories)

    epic_ids = all_stories.map { |s| s["epic_id"] }.compact.uniq
    epic_ids.each do |eid|
      epic = @client.get("/epics/#{eid}")
      write_epic(epic) if epic
    end
  end

  def export_doc(doc_id)
    puts "Fetching document '#{doc_id}'..."
    doc = @client.get("/documents/#{doc_id}")
    return warn("Document '#{doc_id}' not found.") unless doc

    write_doc(doc)
  end

  def export_docs
    puts "Fetching all documents..."
    docs_list = @client.get("/documents")
    return warn("Could not fetch documents.") unless docs_list

    puts "Found #{docs_list.size} documents."
    docs_list.each do |doc_slim|
      doc = @client.get("/documents/#{doc_slim["id"]}")
      write_doc(doc) if doc
    end
  end

  def export_all
    export_all_epics
    export_all_stories
    export_docs
    export_all_files
  end

  private

  def fetch_full_stories(stories_slim)
    stories_slim.filter_map.with_index do |slim, i|
      puts "  Fetching story #{i + 1}/#{stories_slim.size}: ##{slim["id"]}..."
      @client.get("/stories/#{slim["id"]}")
    end
  end

  def export_all_epics
    puts "Fetching all epics..."
    epics = @client.get("/epics", { "includes_description" => "true" })
    return warn("Could not fetch epics.") unless epics

    puts "Found #{epics.size} epics."
    epics.each do |epic|
      full_epic = @client.get("/epics/#{epic["id"]}")
      write_epic(full_epic) if full_epic
    end
  end

  def export_all_stories
    puts "Fetching all stories..."
    all_stories = []
    next_token = nil

    loop do
      body = { "page_size" => 25 }
      body["next"] = next_token if next_token

      result = @client.post("/stories/search", body)
      break unless result

      stories = result["data"] || result
      all_stories.concat(stories) if stories.is_a?(Array)

      next_token = result["next"]
      break unless next_token
    end

    puts "Found #{all_stories.size} stories. Fetching full details..."
    all_stories = fetch_full_stories(all_stories)
    all_stories.each { |story| write_story(story) }
  end

  def export_all_files
    puts "Fetching all files..."
    files = @client.get("/files")
    return warn("Could not fetch files.") unless files

    puts "Found #{files.size} files."
    files.each { |file| write_file_info(file) }
  end

  def export_files_from_stories(stories)
    file_ids = stories.flat_map { |s| s["file_ids"] || [] }.uniq
    return if file_ids.empty?

    puts "Fetching #{file_ids.size} attached files..."
    file_ids.each do |fid|
      file = @client.get("/files/#{fid}")
      write_file_info(file) if file
    end
  end

  def write_epic(epic)
    dir = File.join(@output_dir, "epics")
    FileUtils.mkdir_p(dir)

    filename = sanitize_filename("#{epic["id"]}-#{epic["name"]}")
    path = File.join(dir, "#{filename}.md")

    state = resolve_epic_state(epic["epic_state_id"])
    owners = (epic["owner_ids"] || []).map { |id| resolve_member(id) }.join(", ")
    labels = (epic["labels"] || []).map { |l| l["name"] }.join(", ")

    content = <<~MD
      # #{epic["name"]}

      | Field | Value |
      |-------|-------|
      | **ID** | #{epic["id"]} |
      | **State** | #{state} |
      | **Created** | #{format_date(epic["created_at"])} |
      | **Updated** | #{format_date(epic["updated_at"])} |
      | **Deadline** | #{format_date(epic["deadline"])} |
      | **Owners** | #{owners} |
      | **Labels** | #{labels} |
      | **Started** | #{epic["started"]} |
      | **Completed** | #{epic["completed"]} |
      | **App URL** | #{epic["app_url"]} |

      ## Description

      #{epic["description"] || "_No description_"}

      ## Stats

      | Metric | Value |
      |--------|-------|
      | Total Stories | #{epic.dig("stats", "num_stories_total")} |
      | Stories Done | #{epic.dig("stats", "num_stories_done")} |
      | Stories Started | #{epic.dig("stats", "num_stories_started")} |
      | Stories Unstarted | #{epic.dig("stats", "num_stories_unstarted")} |
      | Total Points | #{epic.dig("stats", "num_points")} |
      | Points Done | #{epic.dig("stats", "num_points_done")} |
    MD

    content = download_and_replace_images(content, path)
    File.write(path, content)
    puts "  Wrote epic: #{path}"
  end

  def write_epic_comments(epic, comments)
    dir = File.join(@output_dir, "epics")
    FileUtils.mkdir_p(dir)

    filename = sanitize_filename("#{epic["id"]}-#{epic["name"]}-comments")
    path = File.join(dir, "#{filename}.md")

    lines = ["# Comments for Epic: #{epic["name"]}\n\n"]

    comments.each do |comment|
      author = resolve_member(comment["author_id"])
      lines << "## #{author} - #{format_date(comment["created_at"])}\n\n"
      lines << "#{comment["text"]}\n\n"

      (comment["comments"] || []).each do |reply|
        reply_author = resolve_member(reply["author_id"])
        lines << "> **#{reply_author}** - #{format_date(reply["created_at"])}\n"
        lines << "> #{reply["text"]}\n\n"
      end

      lines << "---\n\n"
    end

    joined = download_and_replace_images(lines.join, path)
    File.write(path, joined)
    puts "  Wrote epic comments: #{path}"
  end

  def write_story(story)
    dir = File.join(@output_dir, "stories")
    FileUtils.mkdir_p(dir)

    filename = sanitize_filename("#{story["id"]}-#{story["name"]}")
    path = File.join(dir, "#{filename}.md")

    story_type = story["story_type"] || "unknown"
    state = resolve_workflow_state(story["workflow_state_id"])
    owners = (story["owner_ids"] || []).map { |id| resolve_member(id) }.join(", ")
    labels = (story["labels"] || []).map { |l| l["name"] }.join(", ")
    epic_id = story["epic_id"]

    content = <<~MD
      # #{story["name"]}

      | Field | Value |
      |-------|-------|
      | **ID** | #{story["id"]} |
      | **Type** | #{story_type} |
      | **State** | #{state} |
      | **Epic ID** | #{epic_id || "—"} |
      | **Estimate** | #{story["estimate"] || "—"} |
      | **Created** | #{format_date(story["created_at"])} |
      | **Updated** | #{format_date(story["updated_at"])} |
      | **Deadline** | #{format_date(story["deadline"])} |
      | **Owners** | #{owners} |
      | **Labels** | #{labels} |
      | **Completed** | #{story["completed"]} |
      | **Started** | #{story["started"]} |
      | **App URL** | #{story["app_url"]} |

      ## Description

      #{story["description"] || "_No description_"}
    MD

    tasks = story["tasks"] || []
    if tasks.any?
      content += "\n## Tasks\n\n"
      tasks.each do |task|
        check = task["complete"] ? "x" : " "
        content += "- [#{check}] #{task["description"]}\n"
      end
    end

    comments = story["comments"] || []
    if comments.any?
      content += "\n## Comments\n\n"
      comments.sort_by { |c| c["created_at"] || "" }.each do |comment|
        author = resolve_member(comment["author_id"])
        content += "### #{author} - #{format_date(comment["created_at"])}\n\n"
        content += "#{comment["text"]}\n\n"
      end
    end

    branches = story["branches"] || []
    if branches.any?
      content += "\n## Branches\n\n"
      branches.each do |branch|
        content += "- `#{branch["name"]}`\n"
      end
    end

    content = download_and_replace_images(content, path)
    File.write(path, content)
    puts "  Wrote story: #{path}"
  end

  def write_doc(doc)
    dir = File.join(@output_dir, "documents")
    FileUtils.mkdir_p(dir)

    title = doc["title"] || "untitled"
    filename = sanitize_filename("#{doc["id"][0..7]}-#{title}")
    path = File.join(dir, "#{filename}.md")

    body = doc["content_markdown"] || doc["content_html"] || "_No content_"

    content = <<~MD
      # #{title}

      | Field | Value |
      |-------|-------|
      | **ID** | #{doc["id"]} |
      | **Created** | #{format_date(doc["created_at"])} |
      | **Updated** | #{format_date(doc["updated_at"])} |
      | **App URL** | #{doc["app_url"]} |

      ---

      #{body}
    MD

    content = download_and_replace_images(content, path)
    File.write(path, content)
    puts "  Wrote document: #{path}"
  end

  def write_file_info(file)
    dir = File.join(@output_dir, "files")
    FileUtils.mkdir_p(dir)

    filename = sanitize_filename("#{file["id"]}-#{file["name"] || file["filename"] || "file"}")
    path = File.join(dir, "#{filename}.md")

    uploader = resolve_member(file["uploader_id"])
    story_ids = (file["story_ids"] || []).join(", ")

    content = <<~MD
      # #{file["name"] || file["filename"]}

      | Field | Value |
      |-------|-------|
      | **ID** | #{file["id"]} |
      | **Filename** | #{file["filename"]} |
      | **Content Type** | #{file["content_type"]} |
      | **Size** | #{format_bytes(file["size"])} |
      | **Uploaded by** | #{uploader} |
      | **Created** | #{format_date(file["created_at"])} |
      | **Updated** | #{format_date(file["updated_at"])} |
      | **Related Stories** | #{story_ids} |
      | **URL** | #{file["url"]} |
      | **Thumbnail** | #{file["thumbnail_url"]} |
    MD

    if file["description"] && !file["description"].empty?
      content += "\n## Description\n\n#{file["description"]}\n"
    end

    File.write(path, content)
    puts "  Wrote file info: #{path}"
  end

  def resolve_member(member_id)
    return "—" unless member_id

    @members_cache[member_id] ||= begin
      member = @client.get("/members/#{member_id}")
      member ? member.dig("profile", "name") || member.dig("profile", "mention_name") || member_id : member_id
    end
  end

  def resolve_workflow_state(state_id)
    return "—" unless state_id

    load_workflows if @workflows_cache.empty?
    @workflows_cache[state_id] || state_id.to_s
  end

  def resolve_epic_state(state_id)
    return "—" unless state_id

    if @epic_states_cache.empty?
      workflow = @client.get("/epic-workflow")
      if workflow && workflow["epic_states"]
        workflow["epic_states"].each do |s|
          @epic_states_cache[s["id"]] = s["name"]
        end
      end
    end

    @epic_states_cache[state_id] || state_id.to_s
  end

  def load_workflows
    workflows = @client.get("/workflows")
    return unless workflows

    workflows.each do |wf|
      (wf["states"] || []).each do |state|
        @workflows_cache[state["id"]] = state["name"]
      end
    end
  end

  def download_and_replace_images(content, md_file_path)
    images_dir = File.join(@output_dir, "images")
    FileUtils.mkdir_p(images_dir)

    content.gsub(/!\[([^\]]*)\]\((https?:\/\/#{Regexp.escape(MEDIA_HOST)}[^\)]+)\)/) do
      alt_text = $1
      url = $2

      local_name = download_image(url, images_dir)
      if local_name
        relative_path = relative_image_path(md_file_path, File.join(images_dir, local_name))
        "![#{alt_text}](#{relative_path})"
      else
        $&
      end
    end
  end

  def download_image(url, images_dir)
    uri = URI(url)
    ext = File.extname(uri.path).downcase
    ext = ".png" if ext.empty?
    hash = Digest::SHA256.hexdigest(url)[0..11]
    basename = File.basename(uri.path, File.extname(uri.path))
    basename = sanitize_filename(basename)
    basename = "image" if basename.empty?
    local_name = "#{basename}-#{hash}#{ext}"
    local_path = File.join(images_dir, local_name)

    return local_name if File.exist?(local_path)

    puts "    Downloading image: #{File.basename(uri.path)}..."
    fetch_binary(uri, local_path)
  rescue StandardError => e
    warn "    Error downloading image: #{e.message}"
    nil
  end

  def fetch_binary(uri, local_path, redirect_limit = 5)
    return warn("    Too many redirects for: #{uri}") if redirect_limit == 0

    request = Net::HTTP::Get.new(uri)
    if uri.host&.include?(MEDIA_HOST)
      request["Shortcut-Token"] = @client.token
    end

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end

    case response.code.to_i
    when 200
      File.binwrite(local_path, response.body)
      File.basename(local_path)
    when 301, 302, 303, 307, 308
      redirect_uri = URI(response["location"])
      fetch_binary(redirect_uri, local_path, redirect_limit - 1)
    else
      warn "    Failed to download image (#{response.code}): #{uri}"
      nil
    end
  end

  def relative_image_path(from_file, to_file)
    from_dir = File.dirname(File.expand_path(from_file))
    to_abs = File.expand_path(to_file)

    from_parts = from_dir.split("/")
    to_parts = to_abs.split("/")

    common = 0
    from_parts.each_with_index do |part, i|
      break unless to_parts[i] == part
      common = i + 1
    end

    ups = from_parts.size - common
    remaining = to_parts[common..]

    ([".."] * ups + remaining).join("/")
  end

  def sanitize_filename(name)
    name
      .gsub(/[^\w\s\-.]/, "")
      .gsub(/\s+/, "_")
      .slice(0, 200)
  end

  def format_date(date_str)
    return "—" unless date_str

    Time.parse(date_str).strftime("%Y-%m-%d %H:%M")
  rescue ArgumentError
    date_str
  end

  def format_bytes(bytes)
    return "—" unless bytes

    if bytes < 1024
      "#{bytes} B"
    elsif bytes < 1024 * 1024
      "#{(bytes / 1024.0).round(1)} KB"
    else
      "#{(bytes / (1024.0 * 1024)).round(1)} MB"
    end
  end
end

options = {}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby exporter.rb [options]"
  opts.separator ""
  opts.separator "Export data from Shortcut to local markdown files."
  opts.separator ""
  opts.separator "Options:"

  opts.on("--epic ID", Integer, "Export a specific epic and its stories") do |id|
    options[:epic] = id
  end

  opts.on("--team NAME", String, "Export all stories for a team (group)") do |name|
    options[:team] = name
  end

  opts.on("--doc ID", String, "Export a specific document by its public ID") do |id|
    options[:doc] = id
  end

  opts.on("--docs", "Export all documents") do
    options[:docs] = true
  end

  opts.on("--all", "Export everything (epics, stories, docs, files)") do
    options[:all] = true
  end

  opts.on("--output DIR", String, "Output directory (default: #{OUTPUT_DIR})") do |dir|
    options[:output] = dir
  end

  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end

parser.parse!

if options.empty?
  puts parser
  exit 1
end

token = ENV["SHORTCUT_API_TOKEN"]
unless token && !token.empty? && token != "your-api-token-here"
  warn "Error: SHORTCUT_API_TOKEN not set. Create a .env file with your token."
  exit 1
end

output = options[:output] || OUTPUT_DIR
FileUtils.mkdir_p(output)

client = ShortcutClient.new(token)
exporter = MarkdownExporter.new(client, output)

puts "Shortcut Exporter"
puts "Output directory: #{output}"
puts "-" * 40

exporter.export_epic(options[:epic]) if options[:epic]
exporter.export_team(options[:team]) if options[:team]
exporter.export_doc(options[:doc]) if options[:doc]
exporter.export_docs if options[:docs]
exporter.export_all if options[:all]

puts "-" * 40
puts "Export complete!"
