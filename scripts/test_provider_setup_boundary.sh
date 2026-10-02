#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-provider-setup.XXXXXX)
# Exercise the exact production removal, key save and default methods against the same isolated
# settings doubles.
{ echo 'extension AIEnhancementSettingsViewModel {'
  sed -n '/^    func deleteCurrentProvider() -> Bool {/,/^    func saveEditedProvider() {/p' Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel.swift | sed '$d'
  sed -n '/^    func saveManagedProviderBeforeClosing(/,/^    private func selectProviderForUse(/p' Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel.swift | sed '$d'
  sed -n '/^    func saveProviderAPIKey(for providerID: String? = nil, allowsRemoval: Bool = false) -> Bool {/,/^    func createDraftProvider(/p' Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel.swift | sed '$d'
  sed -n '/^    func makeDefaultTextProvider(/,/^    \/\/ MARK: - Helpers/p' Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel+ProviderList.swift | sed '$d'
  echo '}'
} > "$task_test_dir/Removal.swift"
for marker in 'func deleteCurrentProvider' 'func saveManagedProviderBeforeClosing' 'func saveProviderAPIKey' 'static func keepsSavedKeyWhenFieldIsEmptied' 'func makeDefaultTextProvider' 'static func setDefaultAfterVerification'; do
    grep -q "$marker" "$task_test_dir/Removal.swift" || { echo "Production method not extracted: $marker" >&2; exit 1; }
done
xcrun swiftc -parse-as-library \
    "$task_test_dir/Removal.swift" \
    Sources/Fluid/UI/AISettings/ProviderSetupDraft.swift \
    Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel+ProviderSetup.swift \
    Tests/ProviderSetupBoundaryTests.swift \
    -o "$task_test_dir/provider-tests"
"$task_test_dir/provider-tests"
