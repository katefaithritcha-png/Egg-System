import 'package:flutter_test/flutter_test.dart';
import 'package:egg_system_flutter/smartsort_auth.dart';

void main() {
  test('login and reset messages do not reveal whether an email exists', () {
    expect(SmartsortAuth.genericLoginError, 'Wrong email or password.');
    expect(
      SmartsortAuth.resetNotice,
      contains('If that email is registered'),
    );
    expect(SmartsortAuth.genericLoginError.toLowerCase(), isNot(contains('not found')));
  });

  test('new profiles are workers and contain no password material', () {
    final Map<String, dynamic> profile = SmartsortAuth.workerProfileFields(
      email: 'Worker@Farm.com',
      name: 'Ada',
    );
    expect(profile['role'], 'worker');
    expect(profile['email'], 'worker@farm.com');
    expect(SmartsortAuth.profileHasSecret(profile), isFalse);
    expect(
      SmartsortAuth.profileHasSecret(<String, dynamic>{'passwordHash': 'x'}),
      isTrue,
    );
    expect(
      SmartsortAuth.profileHasSecret(<String, dynamic>{'token': 'secret'}),
      isTrue,
    );
  });

  test('the fixed admin email opens the admin site', () {
    expect(
      SmartsortAuth.roleForAccount(
        email: 'katefaithr@gmail.com',
        storedRole: 'worker',
      ),
      'admin',
    );
    expect(
      SmartsortAuth.roleForAccount(
        email: 'worker@farm.com',
        storedRole: 'worker',
      ),
      'worker',
    );
  });

  test('a worker cannot change their own role to admin', () {
    expect(
      SmartsortAuth.roleChangeAllowed(
        actorRole: 'worker',
        actorUid: 'worker-1',
        targetUid: 'worker-1',
        currentRole: 'worker',
        nextRole: 'admin',
      ),
      isFalse,
    );
    expect(
      SmartsortAuth.roleChangeAllowed(
        actorRole: 'worker',
        actorUid: 'worker-1',
        targetUid: 'worker-1',
        currentRole: 'worker',
        nextRole: 'worker',
      ),
      isTrue,
    );
  });

  test('only an admin can change another user role', () {
    expect(
      SmartsortAuth.roleChangeAllowed(
        actorRole: 'worker',
        actorUid: 'worker-1',
        targetUid: 'worker-2',
        currentRole: 'worker',
        nextRole: 'admin',
      ),
      isFalse,
    );
    expect(
      SmartsortAuth.roleChangeAllowed(
        actorRole: 'admin',
        actorUid: 'admin-1',
        targetUid: 'worker-2',
        currentRole: 'worker',
        nextRole: 'admin',
      ),
      isTrue,
    );
    expect(
      SmartsortAuth.roleChangeAllowed(
        actorRole: 'admin',
        actorUid: 'admin-1',
        targetUid: 'admin-1',
        currentRole: 'admin',
        nextRole: 'worker',
      ),
      isFalse,
    );
  });
}
