def exact_keys($expected): . as $object | (($object | keys) == ($expected | sort));
def string: type == "string";
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
)
