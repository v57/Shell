// The database engines behind the sidebar's connections: Database's
// engine-neutral DatabaseKit (PostgreSQL, MySQL, MariaDB, SQL Server, SQLite,
// MongoDB, Redis, Cassandra, ScyllaDB), pure Swift on macOS and iOS. DuckDB stays
// in Database (an optional download there), so Shell doesn't offer it.
@_exported import DatabaseKit

public enum ShellDatabaseEngines {}
