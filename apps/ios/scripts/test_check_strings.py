"""check-strings.py's choice of which compiled strings count (`make test-ios` runs it)."""
import importlib.util
import json
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('check_strings', os.path.join(HERE, 'check-strings.py'))
check_strings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_strings)


def strings(directory, name, source, keys):
    with open(os.path.join(directory, name + '.stringsdata'), 'w') as f:
        json.dump({'source': source, 'tables': {'Localizable': [{'key': k, 'location': {'startingLine': 1}} for k in keys]}}, f)


class UsedTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        arm = os.path.join(self.dir, 'arm64')
        os.makedirs(arm)
        with open(os.path.join(arm, 'HoldMyTrack.SwiftFileList'), 'w') as f:
            f.write('/src/Map.swift\n')
        strings(arm, 'Map', '/src/Map.swift', ['Shown'])
        strings(arm, 'Gone', '/src/Gone.swift', ['Deleted'])
        strings(arm, 'ExtractedAppShortcutsMetadata', 'ExtractedAppShortcutsMetadata', ['Start recording'])
        old = os.path.join(self.dir, 'x86_64')
        os.makedirs(old)
        strings(old, 'Map', '/src/Map.swift', ['Old text'])

    def test_a_compiled_source_counts(self):
        self.assertIn('Shown', check_strings.used(self.dir, ['arm64']))

    def test_a_deleted_source_does_not(self):
        self.assertNotIn('Deleted', check_strings.used(self.dir, ['arm64']))

    def test_generated_metadata_counts(self):
        self.assertIn('Start recording', check_strings.used(self.dir, ['arm64']))

    def test_an_architecture_not_built_does_not(self):
        self.assertNotIn('Old text', check_strings.used(self.dir, ['arm64']))

    def test_without_archs_every_architecture_counts(self):
        self.assertIn('Old text', check_strings.used(self.dir))

    def test_a_stray_file_is_no_architecture(self):
        open(os.path.join(self.dir, '.DS_Store'), 'w').close()
        self.assertIn('Shown', check_strings.used(self.dir))

    def test_no_objects_directory_is_no_strings(self):
        self.assertEqual({}, check_strings.used(os.path.join(self.dir, 'missing')))

    def test_a_file_naming_no_source_does_not_count_beside_a_list(self):
        with open(os.path.join(self.dir, 'arm64', 'Nameless.stringsdata'), 'w') as f:
            json.dump({'tables': {'Localizable': [{'key': 'Nameless'}]}}, f)
        self.assertNotIn('Nameless', check_strings.used(self.dir, ['arm64']))

    def test_a_path_with_a_space_counts_plain_or_escaped(self):
        arm = os.path.join(self.dir, 'arm64')
        with open(os.path.join(arm, 'HoldMyTrack.SwiftFileList'), 'w') as f:
            f.write('/My Projects/src/Map.swift\n/My\\ Projects/src/List.swift\n')
        strings(arm, 'Map', '/My Projects/src/Map.swift', ['Spaced'])
        strings(arm, 'List', '/My Projects/src/List.swift', ['Escaped'])
        found = check_strings.used(self.dir, ['arm64'])
        self.assertIn('Spaced', found)
        self.assertIn('Escaped', found)

    def test_every_file_list_counts(self):
        arm = os.path.join(self.dir, 'arm64')
        with open(os.path.join(arm, 'Other.SwiftFileList'), 'w') as f:
            f.write('/src/Other.swift\n')
        strings(arm, 'Other', '/src/Other.swift', ['Other'])
        found = check_strings.used(self.dir, ['arm64'])
        self.assertIn('Other', found)
        self.assertIn('Shown', found)


if __name__ == '__main__':
    unittest.main()
