package postgresql

import "testing"

// TestDropDatabaseStatement checks that test teardown only uses
// WITH (FORCE) on servers that support it (PostgreSQL 13 and newer).
func TestDropDatabaseStatement(t *testing.T) {
	cases := []struct {
		name       string
		versionNum int
		want       string
	}{
		{"postgresql 12 has no FORCE", 120022, "DROP DATABASE IF EXISTS tf_db"},
		{"last version before 13 has no FORCE", 129999, "DROP DATABASE IF EXISTS tf_db"},
		{"postgresql 13 uses FORCE", 130000, "DROP DATABASE IF EXISTS tf_db WITH (FORCE)"},
		{"postgresql 16 uses FORCE", 160004, "DROP DATABASE IF EXISTS tf_db WITH (FORCE)"},
		{"postgresql 18 uses FORCE", 180001, "DROP DATABASE IF EXISTS tf_db WITH (FORCE)"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := dropDatabaseStatement(tc.versionNum, "tf_db"); got != tc.want {
				t.Errorf("dropDatabaseStatement(%d) = %q, want %q", tc.versionNum, got, tc.want)
			}
		})
	}
}
