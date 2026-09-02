.pragma library

var domain = "omarchy-schema-v1-reference-projection/v1\x00"

function plainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function canonicalId(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function entryId(entry) {
  return canonicalId(plainObject(entry) ? entry.id : entry)
}

function references(config, pluginId) {
  if (!plainObject(config)) return null
  var id = canonicalId(pluginId)
  var out = []
  if (plainObject(config.bar) && canonicalId(config.bar.id) === id)
    out.push({ kind: "selected-bar", location: "bar.id", pluginId: id })
  var sections = ["left", "center", "right"]
  if (plainObject(config.bar) && plainObject(config.bar.layout)) {
    for (var sectionIndex = 0; sectionIndex < sections.length; sectionIndex++) {
      var section = sections[sectionIndex]
      var entries = config.bar.layout[section]
      if (!Array.isArray(entries)) continue
      for (var index = 0; index < entries.length; index++) {
        if (entryId(entries[index]) === id)
          out.push({ kind: "bar-widget", location: "bar.layout." + section + "[" + index + "]", pluginId: id })
      }
    }
  }
  if (Array.isArray(config.plugins)) {
    for (var pluginIndex = 0; pluginIndex < config.plugins.length; pluginIndex++) {
      if (entryId(config.plugins[pluginIndex]) === id)
        out.push({ kind: "plugin", location: "plugins[" + pluginIndex + "]", pluginId: id })
    }
  }
  out.sort(function(left, right) {
    var a = recordBytes(left)
    var b = recordBytes(right)
    var length = Math.min(a.length, b.length)
    for (var i = 0; i < length; i++) if (a[i] !== b[i]) return a[i] - b[i]
    return a.length - b.length
  })
  return out
}

function utf8(value) {
  var text = unescape(encodeURIComponent(String(value)))
  var out = []
  for (var index = 0; index < text.length; index++) out.push(text.charCodeAt(index))
  return out
}

function u32(value) {
  return [(value >>> 24) & 255, (value >>> 16) & 255, (value >>> 8) & 255, value & 255]
}

function field(value) {
  var bytes = utf8(value)
  return u32(bytes.length).concat(bytes)
}

function recordBytes(record) {
  return field(record.kind).concat(field(record.location), field(record.pluginId))
}

function canonicalBytes(config, pluginId) {
  var entries = references(config, pluginId)
  if (entries === null) return null
  var out = utf8(domain)
  for (var index = 0; index < entries.length; index++) out = out.concat(recordBytes(entries[index]))
  return out
}

function base64(bytes) {
  var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var output = ""
  for (var index = 0; index < bytes.length; index += 3) {
    var first = bytes[index]
    var second = index + 1 < bytes.length ? bytes[index + 1] : 0
    var third = index + 2 < bytes.length ? bytes[index + 2] : 0
    var value = (first << 16) | (second << 8) | third
    output += alphabet[(value >>> 18) & 63]
    output += alphabet[(value >>> 12) & 63]
    output += index + 1 < bytes.length ? alphabet[(value >>> 6) & 63] : "="
    output += index + 2 < bytes.length ? alphabet[value & 63] : "="
  }
  return output
}
