def exact_keys($expected): . as $object | (($object | keys) == ($expected | sort));
def string: type == "string";
def object: type == "object";
def nullable_string: . == null or string;
def hex_digest: string and test("^[0-9a-f]{64}$");
def sha_digest: string and test("^sha256:[0-9a-f]{64}$");
def tree_identity: string and test("^omarchy-runtime-tree-sha256-v1:[0-9a-f]{64}$");
def uuid_v4: string and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");
def plugin_id: string and test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not) and (startswith("omarchy.") | not);
def normalized_absolute_path: string and startswith("/") and (contains("//") | not) and (test("(^|/)\\.\\.?(/|$)") | not);
def simple_slot: string and (length > 0 and length <= 128) and (contains("/") | not) and . != "." and . != "..";
def empty_reference_projection: . == "sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432";

def request_facts($operation_id; $plugin_id):
  exact_keys(["callerCandidateIdentity", "destination", "expectedActive", "expectedConfiguration", "operation", "operationId", "pluginId", "protocol", "source", "stageObservation"])
  and .protocol == "legacy-schema-v1-transaction/v1"
  and .operationId == $operation_id
  and .pluginId == $plugin_id
  and (.pluginId | plugin_id)
  and (.operation == "install" or .operation == "update")
  and (.source | exact_keys(["kind", "path"]))
  and .source.kind == "directory"
  and (.source.path | normalized_absolute_path)
  and (.callerCandidateIdentity | tree_identity)
  and (.expectedActive | exact_keys(["identity", "state"]))
  and ((.operation == "install" and .expectedActive.state == "absent" and .expectedActive.identity == "")
       or (.operation == "update" and .expectedActive.state == "present" and (.expectedActive.identity | tree_identity)))
  and (.expectedConfiguration | exact_keys(["referencePolicy", "referenceProjection", "referenceState", "source"]))
  and (.expectedConfiguration.source | exact_keys(["identity", "kind"]))
  and (.expectedConfiguration.source.kind == "user" or .expectedConfiguration.source.kind == "default" or .expectedConfiguration.source.kind == "absent")
  and (.expectedConfiguration.source.identity | string)
  and (.expectedConfiguration.referenceProjection | sha_digest)
  and (.expectedConfiguration.referenceState == "referenced" or .expectedConfiguration.referenceState == "unreferenced")
  and (.expectedConfiguration.referencePolicy == "require-unreferenced" or .expectedConfiguration.referencePolicy == "preserve-observed")
  and (if .expectedConfiguration.referencePolicy == "require-unreferenced" then
         .expectedConfiguration.referenceState == "unreferenced"
         and (.expectedConfiguration.referenceProjection | empty_reference_projection)
       else true end)
  and (if .operation == "install" then .expectedConfiguration.referencePolicy == "require-unreferenced" else true end)
  and (.stageObservation | exact_keys(["provenance", "rawSha256", "referenceProjection", "referenceState"]))
  and (.stageObservation.provenance == "test-injected-o4" or .stageObservation.provenance == "test-injected-o5" or .stageObservation.provenance == "internal-unestablished" or .stageObservation.provenance == "shell-authoritative-o7")
  and (.stageObservation.rawSha256 | sha_digest)
  and (.stageObservation.referenceProjection | sha_digest)
  and (.stageObservation.referenceState == "referenced" or .stageObservation.referenceState == "unreferenced")
  and (.destination | normalized_absolute_path);

def normal_record($operation_id):
  .pluginId as $plugin_id
  | ($plugin_id | plugin_id)
  and (.normalizedRequest | exact_keys(["digest", "facts"]))
  and (.normalizedRequest.digest | hex_digest)
  and (.normalizedRequest.facts | request_facts($operation_id; $plugin_id))
  and (.capabilityHash | hex_digest)
  and (.candidate | exact_keys(["completedSlot", "expected", "observed", "temporarySlot"]))
  and (.candidate.expected == .normalizedRequest.facts.callerCandidateIdentity)
  and (.candidate.temporarySlot | simple_slot)
  and (.candidate.temporarySlot == (".import." + $operation_id))
  and (.candidate.completedSlot == $operation_id)
  and (.candidate.observed | nullable_string)
  and (if .candidate.observed != null then .candidate.observed == .candidate.expected else true end)
  and .corruptEvidenceSha256 == null;

def manual_reason:
  string and (. == "corrupt-journal" or . == "request-digest-mismatch" or . == "missing-or-invalid-completed" or . == "candidate-identity-mismatch" or . == "contradictory-publication" or . == "invalid-temporary" or . == "invalid-completed" or . == "missing-candidate");

def validate_v1($operation_id):
  exact_keys(["candidate", "capabilityHash", "corruptEvidenceSha256", "gate", "normalizedRequest", "operationId", "pluginId", "publication", "reason", "registry", "retainedPrior", "rollback", "schema", "state"])
and .schema == "omarchy-plugin-transaction-journal/v1"
and .operationId == $operation_id
and (.operationId | uuid_v4)
and .gate == "not-established"
and .registry == "not-requested"
and .rollback == "not-applicable"
and .retainedPrior == {"identity": null, "state": "not-captured"}
and (.publication | exact_keys(["state"]))
and (
  if .state == "REQUEST_BOUND" then
    normal_record($operation_id)
    and .candidate.observed == null
    and .publication.state == "not-started"
    and .reason == null
  elif .state == "PUBLICATION_INTENT" then
    normal_record($operation_id)
    and (.candidate.observed | tree_identity)
    and ((.publication.state == "intended" and .reason == null)
         or (.publication.state == "temporary" and .reason == "publication-compensated"))
  elif .state == "STAGED" then
    normal_record($operation_id)
    and (.candidate.observed | tree_identity)
    and .publication.state == "completed-durable"
    and .reason == null
  elif .state == "ABORTED" then
    normal_record($operation_id)
    and (.candidate.observed | tree_identity)
    and .publication.state == "completed-durable"
    and .reason == "owner-aborted"
  elif .state == "RECOVERY_REQUIRED" then
    normal_record($operation_id)
    and (.candidate.observed | tree_identity)
    and .publication.state == "indeterminate"
    and .reason == "publication-indeterminate"
  elif .state == "MANUAL_ATTENTION" then
    if .corruptEvidenceSha256 != null then
      .pluginId == null
      and .normalizedRequest == null
      and .capabilityHash == null
      and .candidate == {"completedSlot": null, "expected": null, "observed": null, "temporarySlot": null}
      and .publication.state == "corrupt-unavailable"
      and (.reason | manual_reason)
      and (.corruptEvidenceSha256 | hex_digest)
    else
      normal_record($operation_id)
      and (.candidate.observed | tree_identity)
      and .publication.state == "contradictory"
      and (.reason | manual_reason)
    end
  else false end
);

def o8_tree: string and test("^omarchy-runtime-tree-sha256-v1:[0-9a-f]{64}$");
def o8_sha: string and test("^sha256:[0-9a-f]{64}$");
def o8_binding: string and test("^[0-9a-f]{64}$");
def o8_state: . == "STAGED" or . == "COMMIT_PREPARED" or . == "LOAD_GATED" or
  . == "LIVE_TREE_EXCHANGED" or . == "GATED_RESCAN_COMPLETED" or
  . == "RELEASE_PENDING" or . == "COMMITTED" or . == "ROLLBACK_STARTED" or
  . == "ROLLED_BACK" or . == "REJECTED" or . == "RECOVERY_REQUIRED" or
  . == "MANUAL_ATTENTION" or . == "ABORTED";
def o8_rejected_reason:
  string and (. == "stale-candidate" or . == "stale-active-tree"
    or . == "stale-configuration-source" or . == "stale-reference-projection"
    or . == "stale-reference-state" or . == "require-unreferenced-violation"
    or . == "plugin-gated-by-another-operation");
def o8_absent: . == {state:"absent",identity:null};
def o8_present: (.state == "present" and (.identity | o8_tree));
def o8_active: (.state == "absent" and (.identity == null or .identity == "")) or o8_present;
def o8_intent:
  exact_keys(["kind","state","sourceSlot","destination","candidate","prior"])
  and (.kind == "install" or .kind == "exchange" or .kind == "rollback-install" or .kind == "rollback-exchange")
  and (.state == "none" or .state == "intended" or .state == "completed")
  and (.sourceSlot | simple_slot) and (.destination | normalized_absolute_path)
  and (.candidate | o8_tree) and ((.prior == null) or (.prior | o8_tree));
def o8_rescan:
  exact_keys(["outcome","shellInstance","generation","scanEpoch","sourceDirectory","expectedTree","observedTree"])
  and (.outcome == "not-requested" or .outcome == "completed")
  and (.shellInstance == null or (.shellInstance | string and length > 0 and length <= 128))
  and (.generation == null or (.generation | type == "number" and floor == . and . >= 0))
  and (.scanEpoch == null or (.scanEpoch | type == "number" and floor == . and . >= 0))
  and (.sourceDirectory == null or (.sourceDirectory | normalized_absolute_path))
  and (.expectedTree == null or (.expectedTree | o8_tree))
  and (.observedTree == null or (.observedTree | o8_tree));
def o8_release:
  exact_keys(["outcome","shellInstance","generation","configurationEpoch"])
  and (.outcome == "not-requested" or .outcome == "authorized")
  and (.shellInstance == null or (.shellInstance | string and length > 0 and length <= 128))
  and (.generation == null or (.generation | type == "number" and floor == . and . >= 0))
  and (.configurationEpoch == null or (.configurationEpoch | type == "number" and floor == . and . >= 0));
def o8_rollback:
  exact_keys(["state","targetRole","target","outcome"])
  and (.state == "not-started" or .state == "intended" or .state == "completed")
  and (.targetRole == "none" or .targetRole == "prior-tree" or .targetRole == "absence")
  and ((.targetRole == "none" and .target == null)
       or (.targetRole == "absence" and .target == {state:"absent",identity:null})
       or (.targetRole == "prior-tree" and .target.state == "present" and (.target.identity | o8_tree)))
  and (.outcome == "not-applicable" or .outcome == "pending" or .outcome == "restored" or .outcome == "indeterminate");
def o8_terminal_receipt:
  exact_keys(["state","intendedJournalState","operationBindingSha256","operationId","pluginId","targetRole","target","shellInstance","generation","scanEpoch","configurationEpoch","outcome"])
  and (.state == "not-requested" or .state == "durable")
  and (.intendedJournalState == null or .intendedJournalState == "COMMITTED" or .intendedJournalState == "ROLLED_BACK")
  and (.operationBindingSha256 == null or (.operationBindingSha256 | o8_binding))
  and (.operationId == null or (.operationId | uuid_v4))
  and (.pluginId == null or (.pluginId | plugin_id))
  and (.targetRole == "none" or .targetRole == "candidate" or .targetRole == "prior-tree" or .targetRole == "absence")
  and (.target == null or .target.state == "absent" or (.target.state == "present" and (.target.identity | o8_tree)))
  and (.shellInstance == null or (.shellInstance | string and length > 0 and length <= 128))
  and (.generation == null or (.generation | type == "number" and floor == . and . >= 0))
  and (.scanEpoch == null or (.scanEpoch | type == "number" and floor == . and . >= 0))
  and (.configurationEpoch == null or (.configurationEpoch | type == "number" and floor == . and . >= 0))
  and (.outcome == "not-requested" or .outcome == "authorized" or .outcome == "restored");
def o8_candidate:
  exact_keys(["expected","observed","temporarySlot","completedSlot","role"])
  and (.expected | o8_tree)
  and (.observed | o8_tree)
  and (.temporarySlot | simple_slot)
  and (.completedSlot | simple_slot)
  and (.role == "candidate");
def o8_publication:
  exact_keys(["state"]) and .state == "completed-durable";
def o8_retained_prior:
  exact_keys(["state","identity","slot"])
  and (.state == "not-captured" or .state == "captured" or .state == "restored" or .state == "absent")
  and (.identity == null or (.identity | o8_tree))
  and (.slot == null or (.slot | simple_slot));
def o8_registry: . == "not-requested" or . == "requested" or . == "completed";
def validate_v2($operation_id):
  exact_keys(["candidate","capabilityHash","corruptEvidenceSha256","gate","normalizedRequest","operationBindingSha256","operationId","pluginId","publication","registry","retainedPrior","rollback","rollbackEvidence","namespaceIntent","rescan","release","terminalReceipt","schema","state","reason"])
  and .schema == "omarchy-plugin-transaction-journal/v2"
  and .operationId == $operation_id and (.operationId | uuid_v4)
  and (.pluginId | plugin_id)
  and (.normalizedRequest | exact_keys(["digest","facts"]))
  and (.normalizedRequest.digest | hex_digest)
  and (.normalizedRequest.facts as $facts | ($facts | request_facts($operation_id; $facts.pluginId)))
  and (.capabilityHash | hex_digest)
  and (.operationBindingSha256 | o8_binding)
  and (.candidate | o8_candidate)
  and (.candidate.expected == .normalizedRequest.facts.callerCandidateIdentity)
  and (.publication | o8_publication)
  and (.gate == "not-established" or .gate == "established")
  and (.registry | o8_registry)
  and (.retainedPrior | o8_retained_prior)
  and (.namespaceIntent | o8_intent)
  and (.rescan | o8_rescan)
  and (.release | o8_release)
  and (.rollback | string)
  and (.rollbackEvidence | o8_rollback)
  and (.terminalReceipt | o8_terminal_receipt)
  and (.state | o8_state)
  and (.reason == null or (.reason | string and length > 0 and length <= 128))
  and (.corruptEvidenceSha256 == null or (.corruptEvidenceSha256 | hex_digest))
  and (
    (.state == "STAGED" and .reason == null and .gate == "not-established" and .registry == "not-requested" and .rollback == "not-applicable" and .namespaceIntent.state == "none" and .rescan.outcome == "not-requested" and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "COMMIT_PREPARED" and .reason == null and .gate == "not-established" and .registry == "not-requested" and .rollback == "not-applicable" and .namespaceIntent.state == "none" and .rescan.outcome == "not-requested" and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "LOAD_GATED" and .reason == null and .gate == "established" and .namespaceIntent.state == "intended" and .rescan.outcome == "not-requested" and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "LIVE_TREE_EXCHANGED" and .reason == null and .gate == "established" and .namespaceIntent.state == "completed" and .rescan.outcome == "not-requested" and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "GATED_RESCAN_COMPLETED" and .reason == null and .gate == "established" and .namespaceIntent.state == "completed" and .rescan.outcome == "completed" and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "RELEASE_PENDING" and .reason == null and .gate == "established" and .namespaceIntent.state == "completed" and .rescan.outcome == "completed" and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "COMMITTED" and .reason == null and .gate == "established" and .namespaceIntent.state == "completed" and .rescan.outcome == "completed" and .release.outcome == "authorized" and .terminalReceipt.state == "durable" and .terminalReceipt.intendedJournalState == "COMMITTED" and .terminalReceipt.targetRole == "candidate" and .terminalReceipt.target.state == "present" and .terminalReceipt.target.identity == .candidate.observed)
    or (.state == "ROLLBACK_STARTED" and .gate == "established" and .rollbackEvidence.state == "intended" and .rollbackEvidence.targetRole != "none" and .rollbackEvidence.outcome == "pending" and .namespaceIntent.state == "intended" and .rescan.outcome == "not-requested" and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "ROLLBACK_STARTED" and .gate == "established" and .rollbackEvidence.state == "completed" and .rollbackEvidence.targetRole != "none" and .rollbackEvidence.outcome == "restored" and .namespaceIntent.state == "completed" and (.rescan.outcome == "not-requested" or .rescan.outcome == "completed") and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "ROLLED_BACK" and .gate == "established" and .rollbackEvidence.state == "completed" and .rollbackEvidence.outcome == "restored" and .rollbackEvidence.targetRole != "none" and .terminalReceipt.state == "durable" and .terminalReceipt.intendedJournalState == "ROLLED_BACK" and .terminalReceipt.targetRole == .rollbackEvidence.targetRole and .terminalReceipt.target == .rollbackEvidence.target and .namespaceIntent.state == "completed" and .rescan.outcome == "completed" and .release.outcome == "authorized")
    or (.state == "REJECTED" and (.reason | o8_rejected_reason) and .gate == "not-established" and .registry == "not-requested" and .rollback == "not-applicable" and .namespaceIntent.state == "none" and .rescan.outcome == "not-requested" and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested")
    or (.state == "RECOVERY_REQUIRED" and .gate == "established")
    or (.state == "MANUAL_ATTENTION" and .gate == "established")
    or (.state == "ABORTED" and .gate == "not-established" and .namespaceIntent.state == "none")
  );

validate_v1($operation_id) or validate_v2($operation_id)
