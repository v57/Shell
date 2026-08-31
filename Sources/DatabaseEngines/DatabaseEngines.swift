// Aggregate target that links the Database package engine libraries
// (MongoDB / PostgreSQL / Redis / SQLite). All four engines are
// cross-platform — the C-driver XCFramework (Cdrivers) ships iOS device +
// simulator slices, and SQLite uses the SDK's system SQLite3 module present
// on both macOS and iOS — so every engine resolves on both platforms. This
// module is the seam the Shell app links to make the DB engines available at
// the app boundary.
public enum DatabaseEngines {}
