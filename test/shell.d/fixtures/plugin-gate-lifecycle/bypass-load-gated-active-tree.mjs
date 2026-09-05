import fs from 'node:fs'

// One comparison, in the copied command only. Keep the later independent
// namespace-layout classifier intact; it must still prevent exposure.
const path = process.argv[2]
const anchor = '[[ $active_observed_identity == "$active_identity" || $active_observed_identity == "${expected_candidate:-}" ]]'
const source = fs.readFileSync(path, 'utf8')
if (source.split(anchor).length !== 2) throw new Error('active identity anchor must occur exactly once')
fs.writeFileSync(path, source.replace(anchor, 'true'))
