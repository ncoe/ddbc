/**
 * DDBC - D DataBase Connector - abstraction layer for RDBMS access, with interface similar to JDBC. 
 * 
 * Source file ddbc/drivers/pgsqlddbc.d.
 *
 * DDBC library attempts to provide implementation independent interface to different databases.
 * 
 * Set of supported RDBMSs can be extended by writing Drivers for particular DBs.
 * Currently it only includes MySQL driver.
 * 
 * JDBC documentation can be found here:
 * $(LINK http://docs.oracle.com/javase/1.5.0/docs/api/java/sql/package-summary.html)$(BR)
 *
 * This module contains implementation of PGSQL Driver which uses patched version of 
 * MYSQLN (native D implementation of PGSQL connector, written by Steve Teale)
 * 
 * Current version of driver implements only unidirectional readonly resultset, which with fetching full result to memory on creation. 
 *
 * You can find usage examples in unittest{} sections.
 *
 * Copyright: Copyright 2013
 * License:   $(LINK www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Author:   Vadim Lopatin
 */
module ddbc.drivers.pgsqlddbc;

import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.stdio;
import std.string;
import std.variant;
import core.sync.mutex;
import ddbc.common;
import ddbc.core;

pragma(lib, "pq");


version(unittest) {
	/*
        To allow unit tests using PostgreSQL server,
     */
	/// change to false to disable tests on real PostgreSQL server
	immutable bool PGSQL_TESTS_ENABLED = true;
	/// change parameters if necessary
	const string PGSQL_UNITTEST_HOST = "localhost";
	const int    PGSQL_UNITTEST_PORT = 5432;
	const string PGSQL_UNITTEST_USER = "testuser";
	const string PGSQL_UNITTEST_PASSWORD = "testpassword";
	const string PGSQL_UNITTEST_DB = "testdb";
	
	static if (PGSQL_TESTS_ENABLED) {
		/// use this data source for tests
		DataSource createUnitTestPGSQLDataSource() {
			PGSQLDriver driver = new PGSQLDriver();
			string url = PGSQLDriver.generateUrl(PGSQL_UNITTEST_HOST, PGSQL_UNITTEST_PORT, PGSQL_UNITTEST_DB);
			string[string] params = PGSQLDriver.setUserAndPassword(PGSQL_UNITTEST_USER, PGSQL_UNITTEST_PASSWORD);
			return new ConnectionPoolDataSourceImpl(driver, url, params);
		}
	}
}


class PGSQLConnection : ddbc.core.Connection {
private:
	string url;
	string[string] params;
	string dbName;
	string username;
	string password;
	string hostname;
	int port = 5432;
	PGconn * conn;
	bool closed;
	bool autocommit;
	Mutex mutex;
	
	
	PGSQLStatement [] activeStatements;
	
	void closeUnclosedStatements() {
		PGSQLStatement [] list = activeStatements.dup;
		foreach(stmt; list) {
			stmt.close();
		}
	}
	
	void checkClosed() {
		if (closed)
			throw new SQLException("Connection is already closed");
	}
	
public:
	
	void lock() {
		mutex.lock();
	}
	
	void unlock() {
		mutex.unlock();
	}
	
	PGconn * getConnection() { return conn; }
	
	
	void onStatementClosed(PGSQLStatement stmt) {
		foreach(index, item; activeStatements) {
			if (item == stmt) {
				remove(activeStatements, index);
				return;
			}
		}
	}
	
	this(string url, string[string] params) {
		mutex = new Mutex();
		this.url = url;
		this.params = params;
		//writeln("parsing url " ~ url);
		string urlParams;
		ptrdiff_t qmIndex = std.string.indexOf(url, '?');
		if (qmIndex >=0 ) {
			urlParams = url[qmIndex + 1 .. $];
			url = url[0 .. qmIndex];
			// TODO: parse params
		}
		string dbName = "";
		ptrdiff_t firstSlashes = std.string.indexOf(url, "//");
		ptrdiff_t lastSlash = std.string.lastIndexOf(url, '/');
		ptrdiff_t hostNameStart = firstSlashes >= 0 ? firstSlashes + 2 : 0;
		ptrdiff_t hostNameEnd = lastSlash >=0 && lastSlash > firstSlashes + 1 ? lastSlash : url.length;
		if (hostNameEnd < url.length - 1) {
			dbName = url[hostNameEnd + 1 .. $];
		}
		hostname = url[hostNameStart..hostNameEnd];
		if (hostname.length == 0)
			hostname = "localhost";
		ptrdiff_t portDelimiter = std.string.indexOf(hostname, ":");
		if (portDelimiter >= 0) {
			string portString = hostname[portDelimiter + 1 .. $];
			hostname = hostname[0 .. portDelimiter];
			if (portString.length > 0)
				port = to!int(portString);
			if (port < 1 || port > 65535)
				port = 5432;
		}
		username = params["user"];
		password = params["password"];
		
		//writeln("host " ~ hostname ~ " : " ~ to!string(port) ~ " db=" ~ dbName ~ " user=" ~ username ~ " pass=" ~ password);

		const char ** keywords = [std.string.toStringz("host"), std.string.toStringz("port"), std.string.toStringz("dbname"), std.string.toStringz("user"), std.string.toStringz("password"), null].ptr;
		const char ** values = [std.string.toStringz(hostname), std.string.toStringz(to!string(port)), std.string.toStringz(dbName), std.string.toStringz(username), std.string.toStringz(password), null].ptr;
		writeln("trying to connect");
		conn = PQconnectdbParams(keywords, values, 0);
		if(conn is null)
			throw new SQLException("Cannot get Postgres connection");
		if(PQstatus(conn) != CONNECTION_OK)
			throw new SQLException(copyCString(PQerrorMessage(conn)));
		closed = false;
		setAutoCommit(true);
		updateConnectionParams();
	}

	void updateConnectionParams() {
		Statement stmt = createStatement();
		scope(exit) stmt.close();
		stmt.executeUpdate("SET NAMES 'utf8'");
	}

	override void close() {
		checkClosed();
		
		lock();
		scope(exit) unlock();
		
		closeUnclosedStatements();
		
		PQfinish(conn);
		closed = true;
	}

	override void commit() {
		checkClosed();
		
		lock();
		scope(exit) unlock();
		
		Statement stmt = createStatement();
		scope(exit) stmt.close();
		stmt.executeUpdate("COMMIT");
	}

	override Statement createStatement() {
		checkClosed();
		
		lock();
		scope(exit) unlock();
		
		PGSQLStatement stmt = new PGSQLStatement(this);
		activeStatements ~= stmt;
		return stmt;
	}
	
	PreparedStatement prepareStatement(string sql) {
		checkClosed();
		
		lock();
		scope(exit) unlock();
		
		PGSQLPreparedStatement stmt = new PGSQLPreparedStatement(this, sql);
		activeStatements ~= stmt;
		return stmt;
	}
	
	override string getCatalog() {
		return dbName;
	}
	
	/// Sets the given catalog name in order to select a subspace of this Connection object's database in which to work.
	override void setCatalog(string catalog) {
		checkClosed();
		if (dbName == catalog)
			return;
		
		lock();
		scope(exit) unlock();

		// TODO:
		throw new SQLException("Not implemented");
		//conn.selectDB(catalog);
		dbName = catalog;
	}
	
	override bool isClosed() {
		return closed;
	}
	
	override void rollback() {
		checkClosed();
		
		lock();
		scope(exit) unlock();
		
		Statement stmt = createStatement();
		scope(exit) stmt.close();
		stmt.executeUpdate("ROLLBACK");
	}
	override bool getAutoCommit() {
		return autocommit;
	}
	override void setAutoCommit(bool autoCommit) {
		checkClosed();
		if (this.autocommit == autoCommit)
			return;
		lock();
		scope(exit) unlock();
		
		Statement stmt = createStatement();
		scope(exit) stmt.close();
		stmt.executeUpdate("SET autocommit = " ~ (autoCommit ? "ON" : "OFF"));
		this.autocommit = autoCommit;
	}
}

class PGSQLStatement : Statement {
private:
	PGSQLConnection conn;
//	Command * cmd;
//	ddbc.drivers.mysql.ResultSet rs;
	PGSQLResultSet resultSet;
	
	bool closed;
	
public:
	void checkClosed() {
		enforceEx!SQLException(!closed, "Statement is already closed");
	}
	
	void lock() {
		conn.lock();
	}
	
	void unlock() {
		conn.unlock();
	}
	
	this(PGSQLConnection conn) {
		this.conn = conn;
	}
	
	ResultSetMetaData createMetadata(PGresult * res) {
		int rows = PQntuples(res);
		int fieldCount = PQnfields(res);
		ColumnMetadataItem[] list = new ColumnMetadataItem[fieldCount];
		for(int i = 0; i < fieldCount; i++) {
			ColumnMetadataItem item = new ColumnMetadataItem();
			//item.schemaName = field.db;
			item.name = copyCString(PQfname(res, i));
			//item.tableName = copyCString(PQfname(res, i));
			int fmt = PQfformat(res, i);
			ulong t = PQftype(res, i);
			item.label = copyCString(PQfname(res, i));
			//item.precision = field.length;
			//item.scale = field.scale;
			//item.isNullable = !field.notNull;
			//item.isSigned = !field.unsigned;
			//item.type = fromPGSQLType(field.type);
//			// TODO: fill more params
			list[i] = item;
		}
		return new ResultSetMetaDataImpl(list);
	}
//	ParameterMetaData createMetadata(ParamDescription[] fields) {
//		ParameterMetaDataItem[] res = new ParameterMetaDataItem[fields.length];
//		foreach(i, field; fields) {
//			ParameterMetaDataItem item = new ParameterMetaDataItem();
//			item.precision = field.length;
//			item.scale = field.scale;
//			item.isNullable = !field.notNull;
//			item.isSigned = !field.unsigned;
//			item.type = fromPGSQLType(field.type);
//			// TODO: fill more params
//			res[i] = item;
//		}
//		return new ParameterMetaDataImpl(res);
//	}
public:
	PGSQLConnection getConnection() {
		checkClosed();
		return conn;
	}

	override ddbc.core.ResultSet executeQuery(string query) {
		throw new SQLException("Not implemented");
		checkClosed();
		lock();
		scope(exit) unlock();

		PGresult * res = PQexec(conn.getConnection(), std.string.toStringz(query));
		enforceEx!SQLException(res !is null, "Failed to execute statement " ~ query);
		auto status = PQresultStatus(res);
		enforceEx!SQLException(status == PGRES_TUPLES_OK, getError());
		scope(exit) PQclear(res);

//		cmd = new Command(conn.getConnection(), query);
//		rs = cmd.execSQLResult();
//		resultSet = new PGSQLResultSet(this, rs, createMetadata(cmd.getResultHeaders().getFieldDescriptions()));
//		return resultSet;
	}

	string getError() {
		return copyCString(PQerrorMessage(conn.getConnection()));
	}

	override int executeUpdate(string query) {
		Variant dummy;
		return executeUpdate(query, dummy);
	}

	override int executeUpdate(string query, out Variant insertId) {
		checkClosed();
		lock();
		scope(exit) unlock();
		PGresult * res = PQexec(conn.getConnection(), std.string.toStringz(query));
		enforceEx!SQLException(res !is null, "Failed to execute statement " ~ query);
		auto status = PQresultStatus(res);
		enforceEx!SQLException(status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK, getError());
		scope(exit) PQclear(res);
		
		string rowsAffected = copyCString(PQcmdTuples(res));
		auto lastid = PQoidValue(res);
		int affected = rowsAffected.length > 0 ? to!int(rowsAffected) : 0;
		insertId = Variant(lastid);
		return affected;
	}

	override void close() {
		checkClosed();
		lock();
		scope(exit) unlock();
		closeResultSet();
		closed = true;
	}

	void closeResultSet() {
		//throw new SQLException("Not implemented");
//		if (cmd == null) {
//			return;
//		}
//		cmd.releaseStatement();
//		delete cmd;
//		cmd = null;
//		if (resultSet !is null) {
//			resultSet.onStatementClosed();
//			resultSet = null;
//		}
	}
}

class PGSQLPreparedStatement : PGSQLStatement, PreparedStatement {
	string query;
	int paramCount;
	ResultSetMetaData metadata;
	ParameterMetaData paramMetadata;
	this(PGSQLConnection conn, string query) {
		super(conn);
		this.query = query;
		throw new SQLException("Not implemented");
//		cmd = new Command(conn.getConnection(), query);
//		cmd.prepare();
//		paramCount = cmd.getParamCount();
	}
	void checkIndex(int index) {
		if (index < 1 || index > paramCount)
			throw new SQLException("Parameter index " ~ to!string(index) ~ " is out of range");
	}
	ref Variant getParam(int index) {
		throw new SQLException("Not implemented");
//		checkIndex(index);
//		return cmd.param(cast(ushort)(index - 1));
	}
public:
	
	/// Retrieves a ResultSetMetaData object that contains information about the columns of the ResultSet object that will be returned when this PreparedStatement object is executed.
	override ResultSetMetaData getMetaData() {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		if (metadata is null)
//			metadata = createMetadata(cmd.getPreparedHeaders().getFieldDescriptions());
//		return metadata;
	}
	
	/// Retrieves the number, types and properties of this PreparedStatement object's parameters.
	override ParameterMetaData getParameterMetaData() {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		if (paramMetadata is null)
//			paramMetadata = createMetadata(cmd.getPreparedHeaders().getParamDescriptions());
//		return paramMetadata;
	}
	
	override int executeUpdate() {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		ulong rowsAffected = 0;
//		cmd.execPrepared(rowsAffected);
//		return cast(int)rowsAffected;
	}
	
	override int executeUpdate(out Variant insertId) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		ulong rowsAffected = 0;
//		cmd.execPrepared(rowsAffected);
//		insertId = cmd.lastInsertID;
//		return cast(int)rowsAffected;
	}
	
	override ddbc.core.ResultSet executeQuery() {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		rs = cmd.execPreparedResult();
//		resultSet = new PGSQLResultSet(this, rs, getMetaData());
//		return resultSet;
	}
	
	override void clearParameters() {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		for (int i = 1; i <= paramCount; i++)
//			setNull(i);
	}
	
	override void setFloat(int parameterIndex, float x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setDouble(int parameterIndex, double x){
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setBoolean(int parameterIndex, bool x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setLong(int parameterIndex, long x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setUlong(int parameterIndex, ulong x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setInt(int parameterIndex, int x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setUint(int parameterIndex, uint x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setShort(int parameterIndex, short x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setUshort(int parameterIndex, ushort x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setByte(int parameterIndex, byte x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setUbyte(int parameterIndex, ubyte x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setBytes(int parameterIndex, byte[] x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		if (x == null)
//			setNull(parameterIndex);
//		else
//			cmd.param(parameterIndex-1) = x;
	}
	override void setUbytes(int parameterIndex, ubyte[] x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		if (x == null)
//			setNull(parameterIndex);
//		else
//			cmd.param(parameterIndex-1) = x;
	}
	override void setString(int parameterIndex, string x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		if (x == null)
//			setNull(parameterIndex);
//		else
//			cmd.param(parameterIndex-1) = x;
	}
	override void setDateTime(int parameterIndex, DateTime x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setDate(int parameterIndex, Date x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setTime(int parameterIndex, TimeOfDay x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.param(parameterIndex-1) = x;
	}
	override void setVariant(int parameterIndex, Variant x) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		if (x == null)
//			setNull(parameterIndex);
//		else
//			cmd.param(parameterIndex-1) = x;
	}
	override void setNull(int parameterIndex) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		checkIndex(parameterIndex);
//		cmd.setNullParam(parameterIndex-1);
	}
	override void setNull(int parameterIndex, int sqlType) {
		throw new SQLException("Not implemented");
//		checkClosed();
//		lock();
//		scope(exit) unlock();
//		setNull(parameterIndex);
	}
}

class PGSQLResultSet : ResultSetImpl {
	private PGSQLStatement stmt;
	private ddbc.drivers.mysql.ResultSet rs;
	ResultSetMetaData metadata;
	private bool closed;
	private int currentRowIndex;
	private int rowCount;
	private int[string] columnMap;
	private bool lastIsNull;
	private int columnCount;
	
	Variant getValue(int columnIndex) {
		checkClosed();
		enforceEx!SQLException(columnIndex >= 1 && columnIndex <= columnCount, "Column index out of bounds: " ~ to!string(columnIndex));
		enforceEx!SQLException(currentRowIndex >= 0 && currentRowIndex < rowCount, "No current row in result set");
		lastIsNull = rs[currentRowIndex].isNull(columnIndex - 1);
		Variant res;
		if (!lastIsNull)
			res = rs[currentRowIndex][columnIndex - 1];
		return res;
	}
	
	void checkClosed() {
		if (closed)
			throw new SQLException("Result set is already closed");
	}
	
public:
	
	void lock() {
		stmt.lock();
	}
	
	void unlock() {
		stmt.unlock();
	}
	
	this(PGSQLStatement stmt, ddbc.drivers.mysql.ResultSet resultSet, ResultSetMetaData metadata) {
		this.stmt = stmt;
		this.rs = resultSet;
		this.metadata = metadata;
		closed = false;
		rowCount = cast(int)rs.length;
		currentRowIndex = -1;
		columnMap = rs.getColNameMap();
		columnCount = cast(int)rs.getColNames().length;
	}
	
	void onStatementClosed() {
		closed = true;
	}
	string decodeTextBlob(ubyte[] data) {
		char[] res = new char[data.length];
		foreach (i, ch; data) {
			res[i] = cast(char)ch;
		}
		return to!string(res);
	}
	
	// ResultSet interface implementation
	
	//Retrieves the number, types and properties of this ResultSet object's columns
	override ResultSetMetaData getMetaData() {
		checkClosed();
		lock();
		scope(exit) unlock();
		return metadata;
	}
	
	override void close() {
		checkClosed();
		lock();
		scope(exit) unlock();
		stmt.closeResultSet();
		closed = true;
	}
	override bool first() {
		checkClosed();
		lock();
		scope(exit) unlock();
		currentRowIndex = 0;
		return currentRowIndex >= 0 && currentRowIndex < rowCount;
	}
	override bool isFirst() {
		checkClosed();
		lock();
		scope(exit) unlock();
		return rowCount > 0 && currentRowIndex == 0;
	}
	override bool isLast() {
		checkClosed();
		lock();
		scope(exit) unlock();
		return rowCount > 0 && currentRowIndex == rowCount - 1;
	}
	override bool next() {
		checkClosed();
		lock();
		scope(exit) unlock();
		if (currentRowIndex + 1 >= rowCount)
			return false;
		currentRowIndex++;
		return true;
	}
	
	override int findColumn(string columnName) {
		checkClosed();
		lock();
		scope(exit) unlock();
		int * p = (columnName in columnMap);
		if (!p)
			throw new SQLException("Column " ~ columnName ~ " not found");
		return *p + 1;
	}
	
	override bool getBoolean(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return false;
		if (v.convertsTo!(bool))
			return v.get!(bool);
		if (v.convertsTo!(int))
			return v.get!(int) != 0;
		if (v.convertsTo!(long))
			return v.get!(long) != 0;
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to boolean");
	}
	override ubyte getUbyte(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return 0;
		if (v.convertsTo!(ubyte))
			return v.get!(ubyte);
		if (v.convertsTo!(long))
			return to!ubyte(v.get!(long));
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to ubyte");
	}
	override byte getByte(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return 0;
		if (v.convertsTo!(byte))
			return v.get!(byte);
		if (v.convertsTo!(long))
			return to!byte(v.get!(long));
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to byte");
	}
	override short getShort(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return 0;
		if (v.convertsTo!(short))
			return v.get!(short);
		if (v.convertsTo!(long))
			return to!short(v.get!(long));
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to short");
	}
	override ushort getUshort(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return 0;
		if (v.convertsTo!(ushort))
			return v.get!(ushort);
		if (v.convertsTo!(long))
			return to!ushort(v.get!(long));
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to ushort");
	}
	override int getInt(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return 0;
		if (v.convertsTo!(int))
			return v.get!(int);
		if (v.convertsTo!(long))
			return to!int(v.get!(long));
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to int");
	}
	override uint getUint(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return 0;
		if (v.convertsTo!(uint))
			return v.get!(uint);
		if (v.convertsTo!(ulong))
			return to!int(v.get!(ulong));
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to uint");
	}
	override long getLong(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return 0;
		if (v.convertsTo!(long))
			return v.get!(long);
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to long");
	}
	override ulong getUlong(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return 0;
		if (v.convertsTo!(ulong))
			return v.get!(ulong);
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to ulong");
	}
	override double getDouble(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return 0;
		if (v.convertsTo!(double))
			return v.get!(double);
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to double");
	}
	override float getFloat(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return 0;
		if (v.convertsTo!(float))
			return v.get!(float);
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to float");
	}
	override byte[] getBytes(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return null;
		if (v.convertsTo!(byte[])) {
			return v.get!(byte[]);
		}
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to byte[]");
	}
	override ubyte[] getUbytes(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return null;
		if (v.convertsTo!(ubyte[])) {
			return v.get!(ubyte[]);
		}
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to ubyte[]");
	}
	override string getString(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return null;
		if (v.convertsTo!(ubyte[])) {
			// assume blob encoding is utf-8
			// TODO: check field encoding
			return decodeTextBlob(v.get!(ubyte[]));
		}
		return v.toString();
	}
	override std.datetime.DateTime getDateTime(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return DateTime();
		if (v.convertsTo!(DateTime)) {
			return v.get!DateTime();
		}
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to DateTime");
	}
	override std.datetime.Date getDate(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return Date();
		if (v.convertsTo!(Date)) {
			return v.get!Date();
		}
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to Date");
	}
	override std.datetime.TimeOfDay getTime(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull)
			return TimeOfDay();
		if (v.convertsTo!(TimeOfDay)) {
			return v.get!TimeOfDay();
		}
		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to TimeOfDay");
	}
	
	override Variant getVariant(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		Variant v = getValue(columnIndex);
		if (lastIsNull) {
			Variant vnull = null;
			return vnull;
		}
		return v;
	}
	override bool wasNull() {
		checkClosed();
		lock();
		scope(exit) unlock();
		return lastIsNull;
	}
	override bool isNull(int columnIndex) {
		checkClosed();
		lock();
		scope(exit) unlock();
		enforceEx!SQLException(columnIndex >= 1 && columnIndex <= columnCount, "Column index out of bounds: " ~ to!string(columnIndex));
		enforceEx!SQLException(currentRowIndex >= 0 && currentRowIndex < rowCount, "No current row in result set");
		return rs[currentRowIndex].isNull(columnIndex - 1);
	}
	
	//Retrieves the Statement object that produced this ResultSet object.
	override Statement getStatement() {
		checkClosed();
		lock();
		scope(exit) unlock();
		return stmt;
	}
	
	//Retrieves the current row number
	override int getRow() {
		checkClosed();
		lock();
		scope(exit) unlock();
		if (currentRowIndex <0 || currentRowIndex >= rowCount)
			return 0;
		return currentRowIndex + 1;
	}
	
	//Retrieves the fetch size for this ResultSet object.
	override int getFetchSize() {
		checkClosed();
		lock();
		scope(exit) unlock();
		return rowCount;
	}
}


// sample URL:
// mysql://localhost:3306/DatabaseName

//String url = "jdbc:postgresql://localhost/test";
//Properties props = new Properties();
//props.setProperty("user","fred");
//props.setProperty("password","secret");
//props.setProperty("ssl","true");
//Connection conn = DriverManager.getConnection(url, props);
class PGSQLDriver : Driver {
	// helper function
	public static string generateUrl(string host, ushort port, string dbname) {
		return "postgresql://" ~ host ~ ":" ~ to!string(port) ~ "/" ~ dbname;
	}
	public static string[string] setUserAndPassword(string username, string password) {
		string[string] params;
		params["user"] = username;
		params["password"] = password;
		params["ssl"] = "true";
		return params;
	}
	override ddbc.core.Connection connect(string url, string[string] params) {
		//writeln("PGSQLDriver.connect " ~ url);
		return new PGSQLConnection(url, params);
	}
}


// C interface of libpq is taken from https://github.com/adamdruppe/misc-stuff-including-D-programming-language-web-stuff/blob/master/postgres.d

string copyCString(const char* c, int actualLength = -1) {
	const(char)* a = c;
	if(a is null)
		return null;
	
	string ret;
	if(actualLength == -1)
	while(*a) {
		ret ~= *a;
		a++;
	}
	else {
		ret = a[0..actualLength].idup;
	}
	
	return ret;
}

extern(C) {
	struct PGconn {};
	struct PGresult {};
	
	void PQfinish(PGconn*);
	PGconn* PQconnectdb(const char*);
	PGconn *PQconnectdbParams(const char **keywords, const char **values, int expand_dbname);

	int PQstatus(PGconn*); // FIXME check return value
	
	const (char*) PQerrorMessage(PGconn*);
	
	PGresult* PQexec(PGconn*, const char*);
	void PQclear(PGresult*);

	
	int PQresultStatus(PGresult*); // FIXME check return value
	char *PQcmdTuples(PGresult *res);

	int PQnfields(PGresult*); // number of fields in a result
	const(char*) PQfname(PGresult*, int); // name of field
	
	int PQntuples(PGresult*); // number of rows in result
	const(char*) PQgetvalue(PGresult*, int row, int column);
	
	size_t PQescapeString (char *to, const char *from, size_t length);
	
	enum int CONNECTION_OK = 0;
	enum int PGRES_COMMAND_OK = 1;
	enum int PGRES_TUPLES_OK = 2;
	
	int PQgetlength(const PGresult *res,
	                int row_number,
	                int column_number);
	int PQgetisnull(const PGresult *res,
	                int row_number,
	                int column_number);

	alias ulong Oid;

	Oid PQftype(const PGresult *res,
	            int column_number);
	Oid PQoidValue(const PGresult *res);

	int PQfformat(const PGresult *res,
	              int column_number);
}

unittest {
	if (PGSQL_TESTS_ENABLED) {
		
		import std.conv;
		DataSource ds = createUnitTestPGSQLDataSource();
	
		auto conn = ds.getConnection();
		assert(conn !is null);
		scope(exit) conn.close();
	}
}