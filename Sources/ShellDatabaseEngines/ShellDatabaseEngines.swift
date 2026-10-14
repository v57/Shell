// The database engines behind the sidebar's connections: DatabasePro's
// engine-neutral DatabaseProKit (PostgreSQL, MySQL, MariaDB, SQL Server, SQLite,
// MongoDB, Redis, Cassandra, ScyllaDB), pure Swift on macOS and iOS. DuckDB stays
// in Database Pro (an optional download there), so Shell doesn't offer it.
@_exported import DatabaseProKit

public enum ShellDatabaseEngines {}
