import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class WorkflowContractTests(unittest.TestCase):
    def read(self, name: str) -> str:
        return (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")

    def test_ci_covers_both_supported_simulator_form_factors(self) -> None:
        text = self.read("test.yml")
        self.assertIn("id: iphone-17-pro", text)
        self.assertIn("id: ipad-pro-11-m5", text)
        self.assertIn("name: iPhone 17 Pro", text)
        self.assertIn("name: iPad Pro 11-inch (M5)", text)
        self.assertIn("${{ matrix.id }}", text)

    def test_release_matrix_retains_resolved_candidate_documentation(self) -> None:
        text = self.read("release-validation.yml")
        self.assertIn("id: iphone-17-pro", text)
        self.assertIn("id: ipad-pro-11-m5", text)
        self.assertIn("${{ matrix.name }}", text)
        self.assertIn('"$RUNNER_TEMP/candidate-docc"', text)
        self.assertNotIn('"$RUNNER_TEMP/release-docc"', text)
        self.assertNotIn("SIMULATOR_NAME='iPhone 17 Pro'", text)

    def test_release_runs_two_clean_simulator_passes_and_performance_gates(self) -> None:
        text = self.read("release-validation.yml")
        self.assertIn("for PASS in 1 2", text)
        self.assertIn("release-simulator-$PASS.xcresult", text)
        self.assertIn("Scripts/run-benchmarks.sh", text)
        self.assertIn("Scripts/run-memory-sweep.sh", text)
        self.assertIn('"$RUNNER_TEMP/release-benchmarks"', text)
        self.assertIn('"$RUNNER_TEMP/release-memory"', text)
        self.assertIn("Scripts/validate-test-result.py", text)
        self.assertIn("release-test-details-$PASS.json", text)

    def test_normal_ci_reconciles_native_result_summary(self) -> None:
        text = self.read("test.yml")
        self.assertIn("xcrun xcresulttool get test-results summary", text)
        self.assertIn("xcrun xcresulttool get test-results tests", text)
        self.assertIn("Scripts/validate-test-result.py", text)
        self.assertIn('--tests "$RUNNER_TEMP/AppLocalVoice-test-details.json"', text)
        self.assertIn("SIMULATOR_OS_BUILD", text)
        self.assertIn("xcrun --sdk iphonesimulator --show-sdk-version", text)
        self.assertNotIn("xcrun --sdk iphoneos --show-sdk-version", text)
        self.assertIn("Scripts/sanitize-evidence-log.py", text)
        self.assertIn('AppLocalVoice-test-details.json"', text)

    def test_measurement_artifacts_retain_native_summaries(self) -> None:
        text = self.read("test.yml")
        self.assertIn("AppLocalVoice-benchmarks-test-summary.json", text)
        self.assertIn("${{ runner.temp }}/AppLocalVoice-memory-sweep", text)

    def test_ci_runs_privacy_and_crash_evidence_validators(self) -> None:
        text = self.read("test.yml")
        release = self.read("release-validation.yml")
        self.assertIn("Scripts/validate-evidence-tooling.sh", text)
        self.assertIn("Scripts/validate-evidence-tooling.sh", release)

    def test_release_provenance_records_resolved_simulator_build(self) -> None:
        text = self.read("release-validation.yml")
        self.assertIn("SIMULATOR_RUNTIME", text)
        self.assertIn("SIMULATOR_OS_BUILD", text)
        self.assertIn('SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"', text)
        self.assertIn('--source-revision "$(git rev-parse HEAD)"', text)
        self.assertIn('--sdk "$(xcrun --sdk iphonesimulator --show-sdk-version)"', text)
        self.assertEqual(text.count("SOURCE_DATE_EPOCH="), 1)
        self.assertIn("timeout-minutes: 90", text)
        self.assertIn("Scripts/sanitize-evidence-log.py", text)
        self.assertIn("release-test-details-1.json", text)
        self.assertIn("release-test-details-2.json", text)

    def test_previous_tag_api_comparison_is_release_only_with_explicit_bootstrap(self) -> None:
        release = self.read("release-validation.yml")
        normal = self.read("test.yml")

        self.assertIn('echo "bootstrap=true"', release)
        self.assertIn('echo "bootstrap=false"', release)
        self.assertIn("No previous reachable semantic-version tag", release)
        self.assertIn("git worktree add --detach", release)
        self.assertIn("Scripts/compare-public-api.py", release)
        self.assertIn('if [[ -z "$PREVIOUS" ]]; then', release)
        self.assertIn("if: steps.tags.outputs.bootstrap != 'true'", release)
        self.assertIn("Record bootstrap API compatibility status", release)
        self.assertNotIn("Scripts/compare-public-api.py", normal)

    def test_ci_keeps_independent_jobs_unblocked_and_uses_nonconflicting_warning_gates(self) -> None:
        text = self.read("test.yml")

        self.assertNotIn("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", text)
        self.assertNotIn("needs: package-and-docs", text)
        self.assertIn("alarm 1200", text)
        self.assertIn("timeout-minutes: 30", text)

    def test_external_actions_are_immutable_commit_pins(self) -> None:
        for path in (ROOT / ".github" / "workflows").glob("*.yml"):
            for line in path.read_text(encoding="utf-8").splitlines():
                if " uses: " not in line:
                    continue
                self.assertRegex(
                    line,
                    r"uses:\s+[^\s@]+@[0-9a-f]{40}",
                    f"un-pinned workflow action in {path}: {line}",
                )


if __name__ == "__main__":
    unittest.main()
