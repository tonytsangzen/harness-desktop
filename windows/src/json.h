#pragma once

#include <string>
#include <vector>

namespace dsh {

// Minimal JSON helpers tailored to npm/node metadata payloads.
// Extracts the value of a top-level `"key"` string property.
bool JsonGetString(const std::string& json, const std::string& key, std::string& out);

// From nodejs.org/dist/index.json: returns the `version` of the first entry
// whose `lts` is a non-empty string (i.e. the newest LTS). Returns false if
// none is found.
bool JsonFirstLTSVersion(const std::string& json, std::string& out);

} // namespace dsh
