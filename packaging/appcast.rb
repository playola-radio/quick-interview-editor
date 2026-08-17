#!/usr/bin/env ruby
# Append a signed <item> to packaging/dist/appcast.xml for the current DMG.
#   packaging/appcast.rb <dmg> <public-download-url> <sign_update_path> [notes_file]
# Inline release notes (CDATA). Idempotent: replaces an item with the same
# sparkle:version. A malformed appcast breaks the update channel, so it validates
# XML before writing.
require "rexml/document"
require "time"
require "open3"

dmg, url, sign_update, notes_file = ARGV
abort "usage: appcast.rb <dmg> <download-url> <sign_update> [notes_file]" unless dmg && url && sign_update
abort "sign_update not executable: #{sign_update}" unless File.executable?(sign_update)
abort "dmg not found: #{dmg}" unless File.file?(dmg)

app = File.join(File.dirname(dmg), "QuickInterviewEditor.app")
# Read plist keys via argv (no shell) so an app path with spaces/quotes/metacharacters
# can't break or inject — matches the Open3 handling used for sign_update below.
def plist(app, key)
  out, _ = Open3.capture2("/usr/libexec/PlistBuddy", "-c", "Print :#{key}",
                          File.join(app, "Contents", "Info.plist"))
  out.strip
end
version    = plist(app, "CFBundleVersion")            # sparkle:version (integer)
short      = plist(app, "CFBundleShortVersionString") # display
min_os     = "15.0.0"                                # 3-component, Sparkle requirement
notes      = notes_file ? File.read(notes_file) : "See the changelog."

# A bad appcast breaks the update channel for everyone, so validate the SEMANTICS
# before writing — not just that the output is well-formed XML. Empty PlistBuddy
# reads (missing key / wrong path) must fail loudly rather than emit blank fields.
abort "CFBundleVersion missing or non-integer: #{version.inspect}" unless version =~ /\A\d+\z/
abort "CFBundleShortVersionString empty" if short.empty?
abort "download url must be https: #{url}" unless url.start_with?("https://")
abort "download url must end in the dmg name" unless url.end_with?(File.basename(dmg))

# Invoke with separate args (no shell interpolation) and require exit 0 before
# trusting stdout — a failed signer must abort, never emit an unsigned enclosure.
sig_line, sig_status = Open3.capture2(sign_update, dmg)
abort "sign_update failed (exit #{sig_status.exitstatus})" unless sig_status.success?
sig_line = sig_line.strip                             # sparkle:edSignature="..." length="..."
abort "sign_update produced no signature" if sig_line.empty?
ed  = sig_line[/sparkle:edSignature="([^"]+)"/, 1] or abort "no edSignature in: #{sig_line}"
len = sig_line[/length="(\d+)"/, 1] or abort "no length in: #{sig_line}"
abort "enclosure length must be > 0" unless len.to_i.positive?

path = File.join(File.dirname(dmg), "appcast.xml")
doc = File.exist?(path) ? REXML::Document.new(File.read(path)) : nil
if doc.nil?
  doc = REXML::Document.new(<<~XML)
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel><title>QuickInterviewEditor</title></channel>
    </rss>
  XML
end
channel = doc.elements["rss/channel"] or abort "appcast has no rss/channel element"
# Idempotent: drop any existing item with this sparkle:version. Collect matches
# first — deleting while iterating REXML's live list skips siblings.
channel.elements.to_a("item").each do |it|
  v = it.elements["sparkle:version"]&.text&.strip
  channel.delete(it) if v == version
end

item = channel.add_element("item")
item.add_element("title").text = "Version #{short}"
item.add_element("pubDate").text = Time.now.utc.rfc2822
item.add_element("sparkle:version").text = version
item.add_element("sparkle:shortVersionString").text = short
item.add_element("sparkle:minimumSystemVersion").text = min_os
desc = item.add_element("description")
desc.add(REXML::CData.new(notes))
enc = item.add_element("enclosure")
enc.add_attribute("url", url)
enc.add_attribute("length", len)
enc.add_attribute("type", "application/octet-stream")
enc.add_attribute("sparkle:edSignature", ed)

# Validate by re-parsing what we're about to write, then re-assert the freshly
# built item carries every required field before it goes near S3. Write with the
# DEFAULT formatter (no pretty-print `indent:`) — REXML's indenter rewrites text
# nodes, injecting whitespace into values like <sparkle:version>, which would both
# corrupt the version Sparkle compares and fail this validation.
out = String.new
doc.write(out)
reparsed = REXML::Document.new(out) or abort "generated appcast is not well-formed"
built = reparsed.elements.to_a("rss/channel/item").find { |i| i.elements["sparkle:version"]&.text&.strip == version } \
  or abort "generated item for version #{version} is missing"
%w[title sparkle:version sparkle:shortVersionString sparkle:minimumSystemVersion].each do |field|
  t = built.elements[field]&.text
  abort "generated item missing #{field}" if t.nil? || t.strip.empty?
end
enc_out = built.elements["enclosure"] or abort "generated item missing enclosure"
%w[url length sparkle:edSignature].each do |attr|
  abort "enclosure missing #{attr}" if (enc_out.attribute(attr)&.value).to_s.empty?
end
File.write(path, out)
puts "Wrote #{path} (version #{version}, len #{len})"
