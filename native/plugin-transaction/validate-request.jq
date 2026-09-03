def exact_keys($expected):
  type == "object" and (keys == ($expected | sort));

def bounded_string($minimum; $maximum):
  type == "string"
  and (utf8bytelength >= $minimum and utf8bytelength <= $maximum)
  and all(explode[]; . >= 32 and . != 127);

def uuid_v4:
  type == "string"
  and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");

def plugin_id:
  bounded_string(1; 128)
  and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")
  and (contains("..") | not)
  and (startswith("omarchy.") | not);

def normalized_absolute_path:
  bounded_string(1; 4096)
  and startswith("/")
  and (contains("//") | not)
  and (test("(^|/)\\.\\.?(/|$)") | not);

def sha256_digest:
  type == "string" and test("^sha256:[0-9a-f]{64}$");

def tree:
  exact_keys(["algorithm", "digest"])
  and .algorithm == "omarchy-runtime-tree-sha256-v1"
  and (.digest | sha256_digest);

def operation_token:
  type == "string"
  and (length >= 43 and length <= 171)
  and test("^[A-Za-z0-9_-]+$");

def configuration_source:
  exact_keys(["identity", "kind"])
  and (.kind == "user" or .kind == "default" or .kind == "absent")
  and (.identity | bounded_string(1; 256));

def expected_configuration:
  exact_keys(["referencePolicy", "referenceProjectionSha256", "referenceState", "source"])
  and (.source | configuration_source)
  and (.referenceProjectionSha256 | sha256_digest)
  and (.referenceState == "referenced" or .referenceState == "unreferenced")
  and (.referencePolicy == "require-unreferenced" or .referencePolicy == "preserve-observed")
  and (if .referencePolicy == "require-unreferenced" then
         .referenceState == "unreferenced"
         and .referenceProjectionSha256 == "sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432"
       else true end);

def stage_request:
  exact_keys(["action", "candidateTree", "expectedActive", "expectedConfiguration", "operation", "operationId", "operationToken", "pluginId", "protocol", "source"])
  and (.operationId | uuid_v4)
  and (.operationToken | operation_token)
  and (.pluginId | plugin_id)
  and (.operation == "install" or .operation == "update")
  and (.source | exact_keys(["kind", "path"]))
  and .source.kind == "directory"
  and (.source.path | normalized_absolute_path)
  and (.candidateTree | tree)
  and (.expectedConfiguration | expected_configuration)
  and (if .operation == "install" then
         (.expectedActive | exact_keys(["state"]))
         and .expectedActive.state == "absent"
         and .expectedConfiguration.referencePolicy == "require-unreferenced"
       else
         (.expectedActive | exact_keys(["state", "tree"]))
         and .expectedActive.state == "present"
         and (.expectedActive.tree | tree)
       end);

if type != "object" then false
elif .protocol != "legacy-schema-v1-transaction/v1" then false
elif .action == "capabilities" then
  exact_keys(["action", "protocol"])
elif .action == "status" then
  exact_keys(["action", "operationId", "protocol"])
  and (.operationId | uuid_v4)
elif .action == "abort" then
  exact_keys(["action", "operationId", "operationToken", "protocol"])
  and (.operationId | uuid_v4)
  and (.operationToken | operation_token)
elif .action == "commit" then
  exact_keys(["action", "operationId", "operationToken", "protocol"])
  and (.operationId | uuid_v4)
  and (.operationToken | operation_token)
elif .action == "stage" then
  stage_request
else false
end
