require "fileutils"
require "open3"
require "rexml/document"
require "uri"
require "yaml"

TROPHY_ENDPOINT = "https://trophy.ryglcloud.net/"
SVG_NAMESPACE = "http://www.w3.org/2000/svg"
SVG_ELEMENTS = %w[
  svg g text title desc metadata defs style path rect circle ellipse line polygon polyline
  linearGradient radialGradient stop clipPath
].freeze

def trophy_svg?(svg)
  return false if svg.match?(/<!DOCTYPE|<!ENTITY|<\?xml-stylesheet|@import/i)
  return false unless svg.scan(/url\s*\(\s*([^)]*)/i).all? { |(target)| target.sub(/\A["']?/, "").start_with?("#") }

  root = REXML::Document.new(svg).root
  return false unless root&.name == "svg" && root.attributes["viewBox"].to_s.match?(/\A0 0 [1-9]\d* [1-9]\d*\z/)

  elements = [root, *REXML::XPath.match(root, ".//*")]
  return false unless elements.count { |element| element.name == "text" } >= 4 && elements.any? { |element| element.name == "path" }

  elements.all? do |element|
    element.namespace == SVG_NAMESPACE && SVG_ELEMENTS.include?(element.name) &&
      element.attributes.each_attribute.none? do |attribute|
        name = attribute.name.downcase
        name.start_with?("on") || (name == "href" && !attribute.value.start_with?("#"))
      end
  end
rescue REXML::ParseException
  false
end

def download_trophy(username, locale, theme, columns)
  query = URI.encode_www_form(
    username: username, theme: theme, locale: locale, "margin-w": 15, "margin-h": 15,
    "no-bg": true, rank: "-C,-B", column: columns,
  )
  response, _, status = Open3.capture3(
    "curl", "--silent", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
    "--max-time", "20", "--max-filesize", "262144", "--write-out", "\n%{http_code} %{content_type}",
    "#{TROPHY_ENDPOINT}?#{query}", binmode: true,
  )
  svg, _, details = response.rpartition("\n")
  http_code, content_type = details.split(" ", 2)
  variant = "#{username}/#{theme}-#{columns}"
  unless status.success? && http_code == "200" && content_type.to_s.split(";").first == "image/svg+xml" && trophy_svg?(svg)
    abort "Could not validate the SVG for #{variant} (HTTP #{http_code || 'unknown'})."
  end

  puts "Validated #{variant}.svg"
  svg.strip.lines.map(&:rstrip).join("\n") + "\n"
end

site_directory = File.expand_path("..", __dir__)
output_directory = ARGV.fetch(0)
config = YAML.safe_load_file(File.join(site_directory, "_config.yml"))
trophy_config = config.fetch("repo_trophies")
exit unless trophy_config.fetch("enabled")

users = YAML.safe_load_file(File.join(site_directory, "_data/repositories.yml")).fetch("github_users")
themes = trophy_config.values_at("theme_light", "theme_dark").uniq
users.product(themes, [3, 4, 6]).each do |username, theme, columns|
  svg = download_trophy(username, config.fetch("lang"), theme, columns)
  user_directory = File.join(output_directory, username)
  FileUtils.mkdir_p(user_directory)
  File.binwrite(File.join(user_directory, "#{theme}-#{columns}.svg"), svg)
end
