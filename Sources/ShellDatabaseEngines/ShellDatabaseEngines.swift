// The sidebar's database connections: Database's interface (DatabaseUI: the connection tree, table and collection
// browsers, query tabs, aggregation pipelines, the inspector and the connection sheets) on its engine-neutral
// DatabaseKit (PostgreSQL, MySQL, MariaDB, SQL Server, SQLite, DuckDB, MongoDB, Redis, Cassandra, ScyllaDB).
@_exported import DatabaseKit
@_exported import DatabaseUI

public enum ShellDatabaseEngines {}
