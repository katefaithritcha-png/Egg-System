import unittest
from pathlib import Path

import firebase_store


ROOT = Path(__file__).resolve().parents[1]
RULES = (ROOT / 'backend' / 'firestore.rules').read_text(encoding='utf-8')


class FirestoreSecurityTests(unittest.TestCase):
    def test_rules_deny_by_default_and_are_not_world_writable(self) -> None:
        self.assertIn("allow read, write: if false", RULES)
        self.assertNotIn('allow read, write: if true', RULES)
        self.assertIn("request.resource.data.role == 'worker'", RULES)
        self.assertIn('request.resource.data.role == resource.data.role', RULES)
        self.assertIn('match /inventory/{id}', RULES)
        self.assertIn('match /reports/{id}', RULES)
        self.assertIn('match /mail_config/{id}', RULES)
        self.assertIn("'passwordHash'", RULES)

    def test_user_profile_sent_to_firestore_has_no_password(self) -> None:
        fields = firebase_store.user_profile_fields(
            email='katefaithr@gmail.com',
            name='Kate Faith',
            role='admin',
            assigned_zone='Operations HQ',
            email_verified=True,
            created_at='2026-10-10T00:00:00Z',
        )
        joined = ' '.join(fields)
        self.assertNotIn('password', joined.lower())
        self.assertNotIn('token', joined.lower())
        self.assertEqual(fields['role']['stringValue'], 'admin')

    def test_mail_config_does_not_include_an_app_password_field(self) -> None:
        source = Path(firebase_store.__file__).read_text(encoding='utf-8')
        self.assertNotIn("'appPassword'", source)
        self.assertNotIn('passwordHash', source)


if __name__ == '__main__':
    unittest.main()
