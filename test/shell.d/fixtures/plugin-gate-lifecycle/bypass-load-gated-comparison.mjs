import fs from 'node:fs'

// Invoked only on the isolated copied command, after its original coordinator
// has been reaped. All other phases and authority comparisons remain intact.
const [path, comparison] = process.argv.slice(2)
const checks = {
  source: '[[ $observed_kind == "$expected_config_kind" && $observed_identity == "$expected_config_identity" ]]',
  projection: '[[ $observed_projection_hash == "$expected_projection" ]]'
}
const anchor = checks[comparison]
if (!anchor) throw new Error('expected source or projection comparison')
const source = fs.readFileSync(path, 'utf8')
if (source.split(anchor).length !== 2) throw new Error('comparison anchor must occur exactly once')
fs.writeFileSync(path, source.replace(anchor, `[[ $authority_phase == load-gated ]] || ${anchor}`))
