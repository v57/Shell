# Databases

Shell opens database connections with the
[Database](https://github.com/v57/Database/blob/main/docs/README.md) app's own interface: the same connection sheet,
tables, queries and editors. The two apps share their saved connections through the vault, so a connection you add
in one shows in the other, on all your devices.

Shell supports PostgreSQL, MySQL, MariaDB, SQL Server, SQLite, MongoDB, Redis, Cassandra and ScyllaDB. On the Mac,
DuckDB is an optional download from Database's interface.

This page covers what Shell adds. For tables, queries, editing rows and the other database pages, see
[Database's guide](https://github.com/v57/Database/blob/main/docs/README.md).

## Add a connection

- Tap **+** on the **Databases** header (**New Database Connection**).
- Or, to reach a database that runs on one of your servers, choose **Database** in that server's menu, or from the
  **+** on a connected server's row. The new connection goes through that server over SSH.

Fill in the connection sheet and save. Shell connects and opens the connection.

## Databases over SSH

A connection with an SSH host goes through that server. Shell talks to the database over the SSH connection itself and
opens no port on your device. A new server's key is asked about in the window before anything is sent.

## Open and browse

Tap a connection to open its overview. Its row shows a green dot while it's open. Tap the row's chevron to see the
databases, schemas, tables (or collections, or keys) and saved queries under it. Tap a table to browse its rows.

On the Mac, the **Data** menu has Database's commands for the open database. See Database's guide for its shortcuts.

## The Databases section

The section shows connections that are open or that you used in the last week. The others wait behind
**Show N More**. A connection saved twice with the same name and address shows once, with a count.

**Sort and Filter** on the header has:

- **Sort By**: **Recently Used** or **Name**;
- **Engine**: **All Engines** or one engine;
- **Show**: **Hide Unused for a Week**.

When you type in the sidebar's filter, every matching connection shows.

## Manage a connection

Touch and hold (or right-click) a connection for **New Query**, **Refresh**, **Disconnect** or **Connect**,
**Edit Connection…**, **Duplicate**, **Copy Link**, **Rename…** and **Delete…**.

**Delete…** asks first. It removes the saved connection, its password and its saved queries from every v57 app. The
database itself isn't touched.

## Insecure logins

PostgreSQL and MySQL logins that would send a password readably (a plain or MD5 password) are refused when the
connection uses neither SSH nor TLS. If you accept the risk for one connection, turn on **Allow insecure login** in its
connection sheet. See Database's guide.
