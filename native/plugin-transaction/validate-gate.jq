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
def o8_tree: string and test("^omarchy-runtime-tree-sha256-v1:[0-9a-f]{64}$");
def o8_target:
  exact_keys(["state","identity"])
  and (.state == "absent" and .identity == null or .state == "present" and (.identity | o8_tree));

def validate_v1:

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
and (.rescan | exact_keys(["expectedTree", "generation", "observedTree", "outcome", "scanEpoch", "shellInstance", "sourceDirectory"]))
and (.rescan.shellInstance | nullable_string)
and (.rescan.generation | nullable_nonnegative_integer)
and (.rescan.scanEpoch | nullable_nonnegative_integer)
and (.rescan.sourceDirectory | nullable_string)
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
    and .rescan == {expectedTree:null,generation:null,observedTree:null,outcome:"not-requested",scanEpoch:null,shellInstance:null,sourceDirectory:null}
    and .release == {configurationEpoch:null,generation:null,outcome:"not-requested",shellInstance:null}
  elif .state == "UNLOAD_ACKNOWLEDGED" then
    .unload == "acknowledged"
    and .rescan == {expectedTree:null,generation:null,observedTree:null,outcome:"not-requested",scanEpoch:null,shellInstance:null,sourceDirectory:null}
    and .release == {configurationEpoch:null,generation:null,outcome:"not-requested",shellInstance:null}
  elif .state == "RESCAN_ACKNOWLEDGED" then
    .unload == "acknowledged"
    and .rescan.outcome == "completed"
    and (.rescan.shellInstance | string) and (.rescan.shellInstance | length > 0)
    and (.rescan.generation | type == "number")
    and (.rescan.scanEpoch | type == "number")
    and .rescan.sourceDirectory == .expected.destination
    and .rescan.expectedTree == .expected.tree
    and .rescan.observedTree == .expected.tree
    and .release == {configurationEpoch:null,generation:null,outcome:"not-requested",shellInstance:null}
  elif .state == "RELEASE_AUTHORIZED" then
    .unload == "acknowledged"
    and .rescan.outcome == "completed"
    and (.rescan.scanEpoch | type == "number")
    and .rescan.sourceDirectory == .expected.destination
    and .rescan.expectedTree == .expected.tree
    and .rescan.observedTree == .expected.tree
    and .release.outcome == "authorized"
    and .release.shellInstance == .rescan.shellInstance
    and .release.generation == .rescan.generation
    and (.release.configurationEpoch | type == "number")
  else false end
);

def validate_v2:
  exact_keys(["expected","operationBindingSha256","operationId","pluginId","release","rescan","schema","state","terminalReceipt","unload","rollback"])
  and .schema == "omarchy-plugin-transaction-gate/v2"
  and (.operationId | uuid_v4)
  and (.pluginId | plugin_id)
  and .pluginId == $plugin_id
  and (.operationBindingSha256 | hex_digest)
  and (.expected | exact_keys(["configurationSource","destination","referencePolicy","referenceProjection","referenceState","tree","targetRole"]))
  and ((.expected.targetRole == "absence" and .expected.tree == null)
       or (.expected.targetRole != "absence" and (.expected.tree | tree_identity)))
  and (.expected.destination | normalized_absolute_path)
  and (.expected.targetRole == "candidate" or .expected.targetRole == "prior-tree" or .expected.targetRole == "absence")
  and (.expected.configurationSource | exact_keys(["identity","kind"]))
  and (.expected.configurationSource.kind == "user" or .expected.configurationSource.kind == "default" or .expected.configurationSource.kind == "absent")
  and (.expected.configurationSource.identity | string)
  and (.expected.referenceProjection | sha_digest)
  and (.expected.referenceState == "referenced" or .expected.referenceState == "unreferenced")
  and (.expected.referencePolicy == "require-unreferenced" or .expected.referencePolicy == "preserve-observed")
  and (.unload == "pending" or .unload == "acknowledged")
  and (.rescan | exact_keys(["expectedTree","generation","observedTree","outcome","scanEpoch","shellInstance","sourceDirectory","targetRole"]))
  and (.rescan.shellInstance | nullable_string)
  and (.rescan.generation | nullable_nonnegative_integer)
  and (.rescan.scanEpoch | nullable_nonnegative_integer)
  and (.rescan.sourceDirectory | nullable_string)
  and (.rescan.expectedTree | nullable_string)
  and (.rescan.observedTree | nullable_string)
  and (.rescan.targetRole == "none" or .rescan.targetRole == "candidate" or .rescan.targetRole == "prior-tree" or .rescan.targetRole == "absence")
  and (.rescan.outcome == "not-requested" or .rescan.outcome == "completed")
  and (.release | exact_keys(["configurationEpoch","generation","outcome","shellInstance"]))
  and (.release.shellInstance | nullable_string)
  and (.release.generation | nullable_nonnegative_integer)
  and (.release.configurationEpoch | nullable_nonnegative_integer)
  and (.release.outcome == "not-requested" or .release.outcome == "authorized")
  and (.rollback | exact_keys(["targetRole","target","outcome"]))
  and (.rollback.targetRole == "none" or .rollback.targetRole == "prior-tree" or .rollback.targetRole == "absence")
  and (.rollback.target == null or (.rollback.target | o8_target))
  and (.rollback.outcome == "not-requested" or .rollback.outcome == "pending" or .rollback.outcome == "completed")
  and (.terminalReceipt | exact_keys(["state","intendedJournalState","operationBindingSha256","operationId","pluginId","targetRole","target","shellInstance","generation","scanEpoch","configurationEpoch","outcome"]))
  and (.terminalReceipt.state == "not-requested" or .terminalReceipt.state == "durable")
  and (.terminalReceipt.intendedJournalState == null or .terminalReceipt.intendedJournalState == "COMMITTED" or .terminalReceipt.intendedJournalState == "ROLLED_BACK")
  and (.terminalReceipt.operationBindingSha256 == null or (.terminalReceipt.operationBindingSha256 | hex_digest))
  and (.terminalReceipt.operationId == null or (.terminalReceipt.operationId | uuid_v4))
  and (.terminalReceipt.pluginId == null or (.terminalReceipt.pluginId | plugin_id))
  and (.terminalReceipt.targetRole == "none" or .terminalReceipt.targetRole == "candidate" or .terminalReceipt.targetRole == "prior-tree" or .terminalReceipt.targetRole == "absence")
  and (.terminalReceipt.target == null or (.terminalReceipt.target | o8_target))
  and (.terminalReceipt.shellInstance == null or (.terminalReceipt.shellInstance | string and length > 0))
  and (.terminalReceipt.generation == null or (.terminalReceipt.generation | type == "number" and . >= 0 and floor == .))
  and (.terminalReceipt.scanEpoch == null or (.terminalReceipt.scanEpoch | type == "number" and . >= 0 and floor == .))
  and (.terminalReceipt.configurationEpoch == null or (.terminalReceipt.configurationEpoch | type == "number" and . >= 0 and floor == .))
  and (.terminalReceipt.outcome == "not-requested" or .terminalReceipt.outcome == "authorized" or .terminalReceipt.outcome == "restored")
  and (if .state == "RELEASE_AUTHORIZED" then
         .release.generation == .rescan.generation
       else true end)
  and (if .state == "TERMINAL_RECEIPT" then
         .rescan.outcome == "completed"
         and .release.outcome == "authorized"
         and .release.shellInstance == .rescan.shellInstance
         and .release.generation == .rescan.generation
         and .terminalReceipt.shellInstance == .release.shellInstance
         and .terminalReceipt.generation == .release.generation
         and .terminalReceipt.generation == .rescan.generation
         and .terminalReceipt.scanEpoch == .rescan.scanEpoch
         and .terminalReceipt.configurationEpoch == .release.configurationEpoch
         and ((.terminalReceipt.intendedJournalState == "COMMITTED" and .terminalReceipt.outcome == "authorized" and .expected.targetRole == "candidate")
              or (.terminalReceipt.intendedJournalState == "ROLLED_BACK" and .terminalReceipt.outcome == "restored" and (.expected.targetRole == "prior-tree" or .expected.targetRole == "absence")))
       else true end)
  and (
    (.state == "GATED" and .unload == "pending" and .rescan.outcome == "not-requested" and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "UNLOAD_ACKNOWLEDGED" and .unload == "acknowledged" and .rescan.outcome == "not-requested" and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "RESCAN_ACKNOWLEDGED" and .unload == "acknowledged" and .rescan.outcome == "completed" and (.rescan.shellInstance | string and length > 0) and (.rescan.generation | type == "number" and . >= 0 and floor == .) and (.rescan.scanEpoch | type == "number" and . >= 0 and floor == .) and .rescan.sourceDirectory == .expected.destination and .rescan.targetRole == .expected.targetRole and ((.expected.targetRole == "absence" and .rescan.expectedTree == null and .rescan.observedTree == null) or (.expected.targetRole != "absence" and .rescan.expectedTree == .expected.tree and .rescan.observedTree == .expected.tree)) and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "RELEASE_AUTHORIZED" and .unload == "acknowledged" and .rescan.outcome == "completed" and (.rescan.shellInstance | string and length > 0) and (.rescan.generation | type == "number" and . >= 0 and floor == .) and (.rescan.scanEpoch | type == "number" and . >= 0 and floor == .) and .rescan.sourceDirectory == .expected.destination and .rescan.targetRole == .expected.targetRole and ((.expected.targetRole == "absence" and .rescan.expectedTree == null and .rescan.observedTree == null) or (.expected.targetRole != "absence" and .rescan.expectedTree == .expected.tree and .rescan.observedTree == .expected.tree)) and .release.outcome == "authorized" and (.release.shellInstance | string and length > 0) and (.release.generation | type == "number" and . >= 0 and floor == .) and (.release.configurationEpoch | type == "number" and . >= 0 and floor == .) and .release.shellInstance == .rescan.shellInstance and .release.generation == .rescan.generation and .terminalReceipt.state == "not-requested")
    or (.state == "TERMINAL_RECEIPT" and .rescan.outcome == "completed" and .rescan.sourceDirectory == .expected.destination and .rescan.targetRole == .expected.targetRole and ((.expected.targetRole == "absence" and .rescan.expectedTree == null and .rescan.observedTree == null) or (.expected.targetRole != "absence" and .rescan.expectedTree == .expected.tree and .rescan.observedTree == .expected.tree)) and .release.outcome == "authorized" and .release.shellInstance == .rescan.shellInstance and .release.generation == .rescan.generation and .terminalReceipt.state == "durable" and ((.terminalReceipt.intendedJournalState == "COMMITTED" and .expected.targetRole == "candidate" and .terminalReceipt.outcome == "authorized") or (.terminalReceipt.intendedJournalState == "ROLLED_BACK" and (.expected.targetRole == "prior-tree" or .expected.targetRole == "absence") and .terminalReceipt.outcome == "restored")) and .terminalReceipt.operationBindingSha256 == .operationBindingSha256 and .terminalReceipt.operationId == .operationId and .terminalReceipt.pluginId == .pluginId and .terminalReceipt.targetRole == .expected.targetRole and ((.expected.targetRole == "absence" and .terminalReceipt.target == {state:"absent",identity:null}) or (.expected.targetRole != "absence" and .terminalReceipt.target == {state:"present",identity:.expected.tree})) and (.terminalReceipt.shellInstance | string and length > 0) and (.terminalReceipt.generation | type == "number" and . >= 0 and floor == .) and (.terminalReceipt.scanEpoch | type == "number" and . >= 0 and floor == .) and (.terminalReceipt.configurationEpoch | type == "number" and . >= 0 and floor == .) and .terminalReceipt.shellInstance == .release.shellInstance and .terminalReceipt.generation == .release.generation and .terminalReceipt.scanEpoch == .rescan.scanEpoch and .terminalReceipt.configurationEpoch == .release.configurationEpoch)
  );

if .schema == "omarchy-plugin-transaction-gate/v1" then validate_v1
elif .schema == "omarchy-plugin-transaction-gate/v2" then validate_v2
else false end
