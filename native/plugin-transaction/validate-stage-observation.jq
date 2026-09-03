def exact_keys($expected):
  type == "object" and (keys == ($expected | sort));

def bounded_string($minimum; $maximum):
  type == "string"
  and (utf8bytelength >= $minimum and utf8bytelength <= $maximum)
  and all(explode[]; . >= 32 and . != 127);

def normalized_absolute_path:
  bounded_string(1; 4096)
  and startswith("/")
  and (contains("//") | not)
  and (test("(^|/)\\.\\.?(/|$)") | not);

def canonical_base64($maximum):
  type == "string"
  and (length >= 4 and length <= $maximum)
  and test("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$");

if type != "object" then false
elif .valid == false then
  exact_keys(["status", "valid"])
  and (.status | bounded_string(1; 128))
elif .valid == true then
  exact_keys(["activeDiscovery", "configurationSource", "discoveryDirectory", "pluginId", "rawBase64", "referenceProjectionBase64", "referenceState", "schema", "status", "transactionStateRoot", "valid"])
  and .schema == "omarchy-plugin-stage-observation/v1"
  and .status == "observed"
  and .pluginId == $plugin_id
  and (.pluginId | bounded_string(1; 128))
  and (.configurationSource | exact_keys(["identity", "kind"]))
  and ((.configurationSource.kind == "user"
          and .configurationSource.identity == "omarchy-shell-config:user:v1")
       or (.configurationSource.kind == "default"
          and (.configurationSource.identity == "omarchy-shell-config:packaged-default:v1"
            or .configurationSource.identity == "omarchy-shell-config:builtin-default:v1")))
  and (.rawBase64 | canonical_base64(43692))
  and (.referenceProjectionBase64 | canonical_base64(5464))
  and (.referenceState == "referenced" or .referenceState == "unreferenced")
  and (if .activeDiscovery.state == "absent" then
         (.activeDiscovery | exact_keys(["state"]))
       else
         (.activeDiscovery | exact_keys(["sourceDirectory", "state"]))
         and .activeDiscovery.state == "present"
         and (.activeDiscovery.sourceDirectory | normalized_absolute_path)
       end)
  and (.discoveryDirectory | normalized_absolute_path)
  and (.transactionStateRoot | normalized_absolute_path)
else false
end
