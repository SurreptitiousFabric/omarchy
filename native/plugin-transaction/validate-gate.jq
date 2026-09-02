def exact_keys($expected): . as $object | (($object | keys) == ($expected | sort));
def string: type == "string";
def nullable_string: . == null or string;
def sha_digest: string and test("^sha256:[0-9a-f]{64}$");
def hex_digest: string and test("^[0-9a-f]{64}$");
def tree_identity: string and test("^omarchy-runtime-tree-sha256-v1:[0-9a-f]{64}$");
def uuid_v4: string and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");
def plugin_id: string and test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not) and (startswith("omarchy.") | not);
def normalized_absolute_path: string and startswith("/") and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not);
def nullable_nonnegative_integer: . == null or (type == "number" and . >= 0 and floor == .);

exact_keys(["expected", "operationId", "operationJournalSha256", "pluginId", "release", "rescan", "schema", "state", "unload"])
and .schema == "omarchy-plugin-transaction-gate/v1"
and (.operationId | uuid_v4)
and (.pluginId | plugin_id)
and .pluginId == $plugin_id
and (.operationJournalSha256 | hex_digest)
and (.expected | exact_keys(["configurationSource", "destination", "referencePolicy", "referenceProjection", "referenceState", "tree"]))
and (.expected.tree | tree_identity)
and (.expected.destination | normalized_absolute_path)
and (.expected.configurationSource | exact_keys(["identity", "kind"]))
and (.expected.configurationSource.kind == "user" or .expected.configurationSource.kind == "default" or .expected.configurationSource.kind == "absent")
and (.expected.configurationSource.identity | string)
and (.expected.referenceProjection | sha_digest)
and (.expected.referenceState == "referenced" or .expected.referenceState == "unreferenced")
and (.expected.referencePolicy == "require-unreferenced" or .expected.referencePolicy == "preserve-observed")
and (if .expected.referencePolicy == "require-unreferenced" then
       .expected.referenceState == "unreferenced"
       and .expected.referenceProjection == "sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432"
     else true end)
and (.unload == "pending" or .unload == "acknowledged")
and (.rescan | exact_keys(["expectedTree", "generation", "observedTree", "outcome", "shellInstance"]))
and (.rescan.shellInstance | nullable_string)
and (.rescan.generation | nullable_nonnegative_integer)
and (.rescan.expectedTree | nullable_string)
and (.rescan.observedTree | nullable_string)
and (.rescan.outcome == "not-requested" or .rescan.outcome == "completed")
and (.release | exact_keys(["configurationEpoch", "generation", "outcome", "shellInstance"]))
and (.release.shellInstance | nullable_string)
and (.release.generation | nullable_nonnegative_integer)
and (.release.configurationEpoch | nullable_nonnegative_integer)
and (.release.outcome == "not-requested" or .release.outcome == "authorized")
and (
  if .state == "GATED" then
    .unload == "pending"
    and .rescan == {expectedTree:null,generation:null,observedTree:null,outcome:"not-requested",shellInstance:null}
    and .release == {configurationEpoch:null,generation:null,outcome:"not-requested",shellInstance:null}
  elif .state == "UNLOAD_ACKNOWLEDGED" then
    .unload == "acknowledged"
    and .rescan == {expectedTree:null,generation:null,observedTree:null,outcome:"not-requested",shellInstance:null}
    and .release == {configurationEpoch:null,generation:null,outcome:"not-requested",shellInstance:null}
  elif .state == "RESCAN_ACKNOWLEDGED" then
    .unload == "acknowledged"
    and .rescan.outcome == "completed"
    and (.rescan.shellInstance | string) and (.rescan.shellInstance | length > 0)
    and (.rescan.generation | type == "number")
    and .rescan.expectedTree == .expected.tree
    and .rescan.observedTree == .expected.tree
    and .release == {configurationEpoch:null,generation:null,outcome:"not-requested",shellInstance:null}
  elif .state == "RELEASE_AUTHORIZED" then
    .unload == "acknowledged"
    and .rescan.outcome == "completed"
    and .rescan.expectedTree == .expected.tree
    and .rescan.observedTree == .expected.tree
    and .release.outcome == "authorized"
    and .release.shellInstance == .rescan.shellInstance
    and .release.generation == .rescan.generation
    and (.release.configurationEpoch | type == "number")
  else false end
)
