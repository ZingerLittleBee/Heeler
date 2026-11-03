import Foundation

/// The SQL behind each query (ADR 0025). Every statement reads one session
/// from `session_v2`, `session_message`, `event_sequence` or
/// `session_inbox`, or for a session only OpenCode 1.x holds from `session`,
/// `message` and `part`, but for `recentSessions`, which reads a directory's
/// roots from `session_v2`, and nothing writes. The statements stay within SQLite
/// 3.25 with JSON1: window functions and `pragma_table_info` are fine, while
/// `->`, `iif`, `FILTER`, `NULLS FIRST`, `HAVING` without `GROUP BY` and
/// `ORDER BY` inside an aggregate are newer. They also stay shallow: SQLite
/// before 3.46 parses on a fixed stack of 100 entries, and the deepest
/// statement needs about 60 of them.
///
/// JSON values lose their JSON subtype when they leave a subquery, a CTE
/// column, or a `CASE` or `coalesce`, and would then embed as strings. So a
/// JSON function's result goes straight into `json_object`, `json_set` or
/// `json_group_array`, and only a value that is always JSON text and crosses
/// such a boundary is wrapped in `json()`. A path that may hold a string or
/// a number is never wrapped: `json()` rejects bare text.
extension OpenCodeProbe {
    /// Slimmed rows larger than this arrive without their data.
    static let rowDataLimit = 1_048_576
    /// Tool output on ordinary reads, in characters.
    static let toolOutputLimit = 16_384
    /// Inbox items, and the characters of each item's text.
    static let inboxItemLimit = 16
    static let inboxTextLimit = 16_384
    /// Open rows a poll reads again by `seq`.
    static let openRowLimit = 64

    static func statements(_ query: OpenCodeQuery) -> [String] {
        if case .recentSessions(let directory, let limit) = query.kind {
            return [versionStatement, tablesStatement, layoutStatement, recentSessions(directory, limit: limit)]
        }
        let session = "'\(query.session?.rawValue ?? "")'"
        let store = Store(query.tables, session: session)
        var statements = [versionStatement] + store.checks
        switch query.kind {
        case .tail(let budget):
            statements += [
                store.sessionStatement("1"),
                newestRows(session, below: nil, budget: budget, in: store),
                firstStatement(session, changed: "1", in: store),
            ] + store.inboxStatements("1")
        case .poll(let cursor):
            let changed = cursor.eventSeq.map { "\(store.counter) IS NOT \($0)" } ?? "1"
            statements += [
                store.sessionStatement(changed),
                // The rows that start inside the budget, then `X` for the
                // first row that does not, from one pass over the window.
                """
                \(pollWindow(session, cursor: cursor, changed: changed, in: store))
                SELECT CASE WHEN acc - len < \(cursor.budget) THEN 'R ' || \(rowObject(dataLimit: rowDataLimit))
                            ELSE 'X' END
                  FROM w WHERE coalesce(previous_start, 0) < \(cursor.budget) ORDER BY seq
                """,
                firstStatement(session, changed: changed, in: store),
                """
                \(with(store.messages))SELECT 'C ' || (SELECT count(*) FROM session_message WHERE session_id = \(session)
                    AND seq BETWEEN \(cursor.lowSeq) AND \(cursor.highSeq)) WHERE \(changed)
                """,
            ] + store.inboxStatements(changed)
        case .older(let before, let budget):
            statements += [
                newestRows(session, below: before, budget: budget, in: store),
                firstStatement(session, changed: "1", in: store),
            ]
        case .row(let seq, let outputLimit):
            let rows = """
                SELECT s.id, s.type, s.seq, s.time_created, s.time_updated, s.data
                  FROM session_message s WHERE s.session_id = \(session) AND s.seq = \(seq)
                """
            statements.append("""
                \(with(store.messages, slimmed(rows, outputLimit: max(0, outputLimit))))SELECT 'R ' || \(rowObject(dataLimit: nil)) FROM r
                """)
        case .recentSessions:
            break
        }
        return statements
    }

    /// What differs between the tables of OpenCode 2 and of 1.x: the checks
    /// before any session is read, the change counter, the session's own line,
    /// the inbox, and for 1.x a `session_message` that stands in for 2's.
    private struct Store {
        var checks: [String]
        /// An integer that moves whenever the session changes, or NULL.
        var counter: String
        /// A CTE named `session_message`, or empty to read the table.
        var messages: String
        var sessionStatement: (_ changed: String) -> String
        var inboxStatements: (_ changed: String) -> [String]

        init(_ tables: OpenCodeQuery.Tables, session: String) {
            switch tables {
            case .v2:
                counter = "(SELECT seq FROM event_sequence WHERE aggregate_id = \(session))"
                messages = ""
                checks = [
                    OpenCodeProbe.tablesStatement, OpenCodeProbe.layoutStatement,
                    "SELECT 'E ' || coalesce(\(counter), '')",
                    // `M 1` when 1.x tables are there too, which may hold it.
                    """
                    SELECT 'M' || CASE WHEN EXISTS (SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = 'message') THEN ' 1' ELSE '' END
                     WHERE NOT EXISTS (SELECT 1 FROM session_v2 WHERE id = \(session))
                    """,
                ]
                sessionStatement = { OpenCodeProbe.sessionStatement(session, changed: $0) }
                inboxStatements = { [OpenCodeProbe.inboxStatement(session, changed: $0)] }
            case .v1:
                counter = OpenCodeProbe.v1Counter(session)
                let messages = OpenCodeProbe.v1Messages(session)
                self.messages = messages
                checks = [
                    OpenCodeProbe.v1LayoutStatement, "SELECT 'E ' || coalesce(\(counter), '')",
                    "SELECT 'M' WHERE NOT EXISTS (SELECT 1 FROM session WHERE id = \(session))",
                ]
                sessionStatement = { OpenCodeProbe.v1SessionStatement(session, changed: $0, messages: messages) }
                inboxStatements = { _ in [] }
            }
        }
    }

    /// `WITH` and the CTEs given that are not empty, or nothing.
    private static func with(_ ctes: String...) -> String {
        let ctes = ctes.filter { !$0.isEmpty }
        return ctes.isEmpty ? "" : "WITH \(ctes.joined(separator: ",\n"))\n"
    }

    /// The directory travels as hex, so nothing of it can leave its literal.
    private static func recentSessions(_ directory: String, limit: Int) -> String {
        let hex = directory.utf8.map { String(format: "%02x", $0) }.joined()
        return """
            SELECT 'Q ' || json_object('id',id,'title',substr(title,1,512),'updated',time_updated)
              FROM session_v2 WHERE directory = CAST(x'\(hex)' AS TEXT) AND parent_id IS NULL
             ORDER BY time_updated DESC LIMIT \(max(0, limit))
            """
    }

    // MARK: Store checks

    static let versionStatement = "SELECT 'V ' || sqlite_version()"

    /// OpenCode 1.x tables, printed only when `session_v2` is absent.
    static let tablesStatement = """
        SELECT 'T ' || m FROM (SELECT group_concat(name, ',') AS m FROM sqlite_master
          WHERE type = 'table' AND name IN ('session', 'message', 'part')
            AND NOT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_v2'))
         WHERE m IS NOT NULL
        """

    /// Every column reading a session names, so a changed layout reads as one
    /// problem rather than as the first statement that fails. `directory` isn't
    /// here: only `recentSessions` uses it, and a store without it shouldn't lose
    /// Chat for that. That statement's "no such column" reads as a layout problem
    /// too, through `OpenCodeProbe`'s reader failure.
    static let layoutStatement = """
        WITH need(t, c) AS (VALUES
          ('session_v2','id'),('session_v2','parent_id'),('session_v2','title'),('session_v2','version'),
          ('session_v2','revert'),('session_v2','time_updated'),
          ('session_message','id'),('session_message','session_id'),('session_message','type'),
          ('session_message','seq'),('session_message','time_created'),('session_message','time_updated'),
          ('session_message','data'),('event_sequence','aggregate_id'),('event_sequence','seq'),
          ('session_inbox','id'),('session_inbox','session_id'),('session_inbox','type'),
          ('session_inbox','payload'),('session_inbox','delivery'),('session_inbox','enqueued_seq'),
          ('session_inbox','time_created'))
        SELECT 'L ' || m FROM (SELECT group_concat(t || '.' || c, ',') AS m FROM need
          WHERE NOT EXISTS (SELECT 1 FROM pragma_table_info(need.t) p WHERE p.name = need.c))
         WHERE m IS NOT NULL
        """

    // MARK: Session, first row and inbox

    /// A staged revert's patches stay in the store: the line carries only
    /// the boundary message, its `seq` and a file count.
    fileprivate static func sessionStatement(_ session: String, changed: String) -> String {
        """
        SELECT 'S ' || json_object('k','session','id',id,'parent',parent_id,'title',substr(title,1,512),
          'version',version,
          'revertMessage', json_extract(CASE WHEN json_valid(revert) THEN revert END, '$.messageID'),
          'revertFiles', json_array_length(CASE WHEN json_valid(revert) THEN revert END, '$.files'),
          'revertSeq', (SELECT m.seq FROM session_message m WHERE m.session_id = \(session)
             AND m.id = json_extract(CASE WHEN json_valid(session_v2.revert) THEN session_v2.revert END, '$.messageID')),
          'updated', time_updated)
          FROM session_v2 WHERE id = \(session) AND \(changed)
        """
    }

    private static func firstStatement(_ session: String, changed: String, in store: Store) -> String {
        """
        \(with(store.messages))SELECT 'F ' || coalesce((SELECT min(seq) FROM session_message WHERE session_id = \(session)), '') \
        WHERE \(changed)
        """
    }

    fileprivate static func inboxStatement(_ session: String, changed: String) -> String {
        """
        SELECT 'I ' || json_object('k','inbox',
            'items', json(coalesce((SELECT json_group_array(json(item)) FROM (
               SELECT json_object('id',id,'type',type,'delivery',delivery,'seq',enqueued_seq,'tc',time_created,
                 'text', substr(json_extract(CASE WHEN json_valid(payload) THEN payload END,'$.text'),1,\(inboxTextLimit)),
                 'n', length(json_extract(CASE WHEN json_valid(payload) THEN payload END,'$.text')),
                 'files', json(coalesce((SELECT json_group_array(json_extract(f.value,'$.name'))
                            FROM json_each(CASE WHEN json_valid(payload) THEN payload END,'$.files') f
                           WHERE f.type = 'object'), '[]'))) AS item
                 FROM session_inbox WHERE session_id = \(session) ORDER BY enqueued_seq LIMIT \(inboxItemLimit))), '[]')),
            'more', (SELECT max(count(*) - \(inboxItemLimit), 0) FROM session_inbox WHERE session_id = \(session)))
         WHERE \(changed)
        """
    }

    // MARK: Rows

    /// The newest rows within `budget` bytes of slimmed JSON, below `below`
    /// when given, printed oldest first. The newest row always prints. A
    /// prefilter on the stored length bounds how many rows are slimmed.
    private static func newestRows(_ session: String, below: Int64?, budget: Int, in store: Store) -> String {
        let bound = below.map { " AND seq < \($0)" } ?? ""
        let rows = """
            SELECT s.id, s.type, s.seq, s.time_created, s.time_updated, s.data
              FROM session_message s JOIN raw ON raw.seq = s.seq
             WHERE s.session_id = \(session) AND raw.racc - raw.rlen < 4 * \(budget)
            """
        let raw = """
            raw AS (SELECT seq, length(data) AS rlen,
                           sum(length(data)) OVER (ORDER BY seq DESC ROWS UNBOUNDED PRECEDING) AS racc
                      FROM session_message WHERE session_id = \(session)\(bound))
            """
        let window = """
            w AS (SELECT *, length(CAST(d AS BLOB)) AS len,
                         sum(length(CAST(d AS BLOB))) OVER (ORDER BY seq DESC ROWS UNBOUNDED PRECEDING) AS acc
                    FROM r)
            """
        return """
            \(with(store.messages, raw, slimmed(rows, outputLimit: toolOutputLimit), window))\
            SELECT 'R ' || \(rowObject(dataLimit: rowDataLimit))
              FROM w WHERE acc - len < \(budget) ORDER BY seq
            """
    }

    /// The rows a poll reads, oldest first with a running total and where
    /// the row before each starts: newer than the window, still open, or
    /// updated inside it since the last read.
    private static func pollWindow(
        _ session: String, cursor: OpenCodePollCursor, changed: String, in store: Store
    ) -> String {
        let open = cursor.openRows.prefix(openRowLimit).map(String.init).joined(separator: ",")
        let rows = """
            SELECT s.id, s.type, s.seq, s.time_created, s.time_updated, s.data
              FROM session_message s
             WHERE s.session_id = \(session) AND \(changed)
               AND (s.seq > \(cursor.highSeq) OR s.seq IN (\(open.isEmpty ? "NULL" : open))
                    OR (s.seq >= \(cursor.lowSeq) AND s.time_updated >= \(cursor.updatedSince)))
            """
        let window = """
            w AS (SELECT *, length(CAST(d AS BLOB)) AS len,
                         sum(length(CAST(d AS BLOB))) OVER (ORDER BY seq ROWS UNBOUNDED PRECEDING) AS acc,
                         sum(length(CAST(d AS BLOB)))
                           OVER (ORDER BY seq ROWS BETWEEN UNBOUNDED PRECEDING AND 2 PRECEDING) AS previous_start
                    FROM r)
            """
        return with(store.messages, slimmed(rows, outputLimit: toolOutputLimit), window)
    }

    /// The CTEs that slim the rows `rows` selects from `session_message`:
    /// `m` holds those rows; `items` each step's content items, with a tool
    /// call's output text and changed files read out; `slim_items` each item
    /// as Chat reads it; and `r` each row as Chat reads it, as `f` and `d`.
    ///
    /// SQLite before 3.46 parses on a fixed stack of 100 entries and fails
    /// a statement nested deeper with "parser stack overflow" (Debian 12 and
    /// Ubuntu 24.04 ship such SQLite). So an item is built at the top of its
    /// own CTE rather than inside its row's expression, and a step gathers
    /// its items by `seq`, in `json_each` order.
    private static func slimmed(_ rows: String, outputLimit: Int) -> String {
        """
        m AS (\(rows)),
        items AS (SELECT m.seq, c.key AS i, CASE WHEN c.type = 'object' THEN c.value END AS v,
                         \(toolOutput) AS out, \(changedFiles) AS files
                    FROM m, json_each(CASE WHEN m.type = 'assistant' AND json_valid(m.data) THEN m.data END,
                                      '$.content') c),
        slim_items AS (SELECT seq, i, \(item(outputLimit: outputLimit)) AS item FROM items),
        r AS (SELECT m.id, m.type, m.seq, m.time_created AS tc, m.time_updated AS tu,
                     \(finalFlag) AS f, \(slim) AS d
                FROM m)
        """
    }

    /// One `{"k":"row",…}` line from the `w` columns. Over `dataLimit` the
    /// row carries its size as `big` instead of `d`.
    private static func rowObject(dataLimit: Int?) -> String {
        let head = """
            'k','row','id',id,'type',type,'seq',seq,'tc',tc,'tu',tu,\
            'f',json(CASE WHEN f THEN 'true' ELSE 'false' END)
            """
        guard let dataLimit else { return "json_object(\(head),'d',json(d))" }
        return """
            CASE WHEN len <= \(dataLimit) THEN json_object(\(head),'d',json(d))
                   ELSE json_object(\(head),'big',len) END
            """
    }

    /// Whether a row can still change: a step, compaction or shell command
    /// that has not finished.
    private static let finalFlag = """
        CASE WHEN json_valid(m.data) THEN CASE
          WHEN m.type IN ('assistant', 'shell')
            THEN coalesce(json_type(m.data, '$.time.completed'), '') IN ('integer', 'real')
          WHEN m.type = 'compaction' THEN coalesce(json_extract(m.data, '$.status'), '') <> 'running'
          ELSE 1 END ELSE 1 END
        """

    /// A shell-mode command's output text. OpenCode 2.0.32 keeps it in an
    /// object with its cursor, size and truncation; a string reads as is.
    private static let shellOutput = """
        CASE json_type(m.data, '$.output') WHEN 'object' THEN json_extract(m.data, '$.output.output') \
        ELSE json_extract(m.data, '$.output') END
        """

    /// The row's data, cut to what Chat shows. A row that is not JSON reads
    /// as `{"k":"invalid"}`. A step keeps its items from `slim_items`, and a
    /// failed compaction its error's type and the first 16 Ki characters of
    /// its message.
    private static let slim = """
        CASE WHEN json_valid(m.data) THEN CASE
          WHEN m.type = 'assistant' THEN \(assistant)
          WHEN m.type = 'user' THEN \(user)
          WHEN m.type = 'compaction' THEN json_object('status', json_extract(m.data, '$.status'),
              'reason', json_extract(m.data, '$.reason'),
              'summary', substr(json_extract(m.data, '$.summary'), 1, 65536),
              'error', json(CASE WHEN json_type(m.data, '$.error') = 'object' THEN json_object(
                'type', json_extract(m.data, '$.error.type'),
                'message', substr(json_extract(m.data, '$.error.message'), 1, 16384)) END),
              'time', json_extract(m.data, '$.time'))
          WHEN m.type = 'shell' THEN json_object('command', json_extract(m.data, '$.command'),
              'status', json_extract(m.data, '$.status'), 'exit', json_extract(m.data, '$.exit'),
              'output', substr(\(shellOutput), 1, \(toolOutputLimit)),
              'n', length(\(shellOutput)), 'time', json_extract(m.data, '$.time'))
          WHEN m.type IN ('synthetic', 'system') THEN json_object(\(note))
          WHEN m.type = 'skill' THEN json_object(\(note),
              'skill', json_extract(m.data, '$.skill'), 'name', json_extract(m.data, '$.name'))
          WHEN m.type IN ('idle', 'agent-switched', 'model-switched', 'location-switched') THEN
            CASE WHEN length(CAST(m.data AS BLOB)) < 4096 THEN m.data
                 ELSE json_object('time', json_extract(m.data, '$.time')) END
          ELSE json_object('time', json_extract(m.data, '$.time')) END
        ELSE json_object('k', 'invalid') END
        """

    /// A step without its provider state or snapshot, its content the step's
    /// items from `slim_items`.
    private static let assistant = """
        json_set(json_remove(m.data, '$.providerState', '$.snapshot', '$.content'), '$.content',
          json((SELECT json_group_array(json(s.item)) FROM slim_items s WHERE s.seq = m.seq)))
        """

    /// One content item of `items`, keeping its index as `_i`.
    private static func item(outputLimit: Int) -> String {
        """
        CASE WHEN v IS NULL THEN json_object('_i', i) ELSE CASE json_extract(v, '$.type')
          WHEN 'text' THEN json_object('_i', i, 'type', 'text',
            'text', substr(json_extract(v, '$.text'), 1, 65536),
            'n', length(json_extract(v, '$.text')),
            'phase', coalesce(json_extract(v, '$.state.phase'), json_extract(v, '$.state.openai.phase')))
          WHEN 'reasoning' THEN json_object('_i', i, 'type', 'reasoning',
            'text', substr(json_extract(v, '$.text'), 1, 65536),
            'n', length(json_extract(v, '$.text')),
            'time', json_extract(v, '$.time'))
          WHEN 'tool' THEN json_object('_i', i, 'type', 'tool',
            'id', json_extract(v, '$.id'), 'name', json_extract(v, '$.name'),
            'status', json_extract(v, '$.state.status'),
            'input', json(\(toolInput)),
            'error', json_extract(v, '$.state.error'),
            'meta', json(\(toolMetadata)),
            'out', substr(out, 1, \(outputLimit)),
            'outN', length(out),
            'time', json_extract(v, '$.time'))
          ELSE json_object('_i', i, 'type', json_extract(v, '$.type')) END END
        """
    }

    /// A tool call's output texts joined by newlines, from an `items` row.
    private static let toolOutput = """
        (SELECT group_concat(json_extract(o.value, '$.text'), char(10))
           FROM json_each(CASE WHEN c.type = 'object' THEN c.value END, '$.state.content') o
          WHERE o.type = 'object')
        """

    /// The files a tool call changed, from an `items` row, each patch cut at
    /// 64 Ki characters.
    private static let changedFiles = """
        (SELECT json_group_array(json_object(
            'file', coalesce(json_extract(f.value, '$.file'), json_extract(f.value, '$.relativePath'),
                             json_extract(f.value, '$.filePath')),
            'status', coalesce(json_extract(f.value, '$.status'), json_extract(f.value, '$.type')),
            'additions', json_extract(f.value, '$.additions'),
            'deletions', json_extract(f.value, '$.deletions'),
            'patch', substr(coalesce(json_extract(f.value, '$.patch'), json_extract(f.value, '$.diff')),
                            1, 65536)))
           FROM json_each(CASE WHEN c.type = 'object' THEN c.value END, '$.state.metadata.files') f
          WHERE f.type = 'object')
        """

    /// An input of 8 KiB or less whole; a larger one keeps the fields a row
    /// names; a text input as a string.
    private static let toolInput = """
        CASE json_type(v, '$.state.input')
          WHEN 'object' THEN
            CASE WHEN length(CAST(json_extract(v, '$.state.input') AS BLOB)) <= 8192
              THEN json_extract(v, '$.state.input')
              ELSE json_object('filePath', json_extract(v, '$.state.input.filePath'),
                'path', json_extract(v, '$.state.input.path'),
                'command', substr(json_extract(v, '$.state.input.command'), 1, 2048),
                'pattern', json_extract(v, '$.state.input.pattern'),
                'description', json_extract(v, '$.state.input.description'),
                'url', json_extract(v, '$.state.input.url'),
                'query', json_extract(v, '$.state.input.query'),
                'agent', json_extract(v, '$.state.input.agent'),
                'prompt', substr(json_extract(v, '$.state.input.prompt'), 1, 2048),
                'questions', json_extract(v, '$.state.input.questions')) END
          WHEN 'text' THEN json_quote(substr(json_extract(v, '$.state.input'), 1, 2048))
          END
        """

    /// Tool metadata without diagnostics, previews, full output or file
    /// contents; the diff cut at 64 Ki characters, and `files` from `items`.
    private static let toolMetadata = """
        CASE WHEN json_type(v, '$.state.metadata') = 'object' THEN json_replace(
          json_remove(json_extract(v, '$.state.metadata'), '$.diagnostics', '$.preview',
            '$.output', '$.loaded', '$.filediff.before', '$.filediff.after'),
          '$.diff', substr(json_extract(v, '$.state.metadata.diff'), 1, 65536),
          '$.files', json(files)) END
        """

    private static let user = """
        json_object('text', substr(json_extract(m.data, '$.text'), 1, 262144),
          'n', length(json_extract(m.data, '$.text')),
          'files', json(coalesce((SELECT json_group_array(json_object('name', json_extract(f.value, '$.name'),
                'mime', json_extract(f.value, '$.mime'), 'mention', json_extract(f.value, '$.mention')))
              FROM json_each(m.data, '$.files') f WHERE f.type = 'object'), '[]')),
          'agents', json_extract(m.data, '$.agents'),
          'time', json_extract(m.data, '$.time'))
        """

    /// The `json_object` arguments shared by synthetic, system and skill rows.
    private static let note = """
        'text', substr(json_extract(m.data, '$.text'), 1, 16384),
              'n', length(json_extract(m.data, '$.text')),
              'description', json_extract(m.data, '$.description'),
              'metadata', json(CASE WHEN json_type(m.data, '$.metadata') = 'object' THEN json_object(
                'source', json_extract(m.data, '$.metadata.source'),
                'childID', json_extract(m.data, '$.metadata.childID'),
                'state', json_extract(m.data, '$.metadata.state'),
                'exit', json_extract(m.data, '$.metadata.exit'),
                'notice', json_extract(m.data, '$.metadata.notice'),
                'jobID', json_extract(m.data, '$.metadata.jobID'),
                'shellID', json_extract(m.data, '$.metadata.shellID'),
                'truncated', json_extract(m.data, '$.metadata.truncated')) END),
              'time', json_extract(m.data, '$.time')
        """

    // MARK: OpenCode 1.x

    /// The columns the 1.x statements name, checked as `layoutStatement` checks 2's.
    fileprivate static let v1LayoutStatement = """
        WITH need(t, c) AS (VALUES
          ('session','id'),('session','parent_id'),('session','title'),('session','version'),
          ('session','revert'),('session','time_updated'),
          ('message','id'),('message','session_id'),('message','time_created'),('message','time_updated'),
          ('message','data'),
          ('part','id'),('part','message_id'),('part','session_id'),('part','time_updated'),('part','data'))
        SELECT 'L ' || m FROM (SELECT group_concat(t || '.' || c, ',') AS m FROM need
          WHERE NOT EXISTS (SELECT 1 FROM pragma_table_info(need.t) p WHERE p.name = need.c))
         WHERE m IS NOT NULL
        """

    /// 1.x keeps no event counter. This one is the newest `time_updated` of the
    /// session, its messages and its parts, with how many of them there are, so
    /// a write or a deletion moves it.
    fileprivate static func v1Counter(_ session: String) -> String {
        """
        (SELECT max(t) * 4096 + sum(n) % 4096 FROM (
           SELECT time_updated AS t, 0 AS n FROM session WHERE id = \(session)
           UNION ALL SELECT max(time_updated), count(*) FROM message WHERE session_id = \(session)
           UNION ALL SELECT max(time_updated), count(*) FROM part WHERE session_id = \(session)))
        """
    }

    fileprivate static func v1SessionStatement(_ session: String, changed: String, messages: String) -> String {
        """
        \(with(messages))SELECT 'S ' || json_object('k','session','id',id,'parent',parent_id,
          'title',substr(title,1,512),'version',version,
          'revertMessage', json_extract(CASE WHEN json_valid(revert) THEN revert END, '$.messageID'),
          'revertSeq', (SELECT m.seq FROM session_message m WHERE m.session_id = \(session)
             AND m.id = json_extract(CASE WHEN json_valid(session.revert) THEN session.revert END, '$.messageID')),
          'updated', time_updated)
          FROM session WHERE id = \(session) AND \(changed)
        """
    }

    /// A `session_message` of 1.x's messages in 2's shape (OpenCode 1.19.5's
    /// tables): a user message's own text and files, a step's text, reasoning
    /// and tool parts as its content, and a compaction's summary. `seq` is the
    /// message's place by `time_created`, then id; `time_updated` the newest of
    /// the message's and its parts'. The user message that asks for a
    /// compaction has a type Chat does not show, and a message that is not JSON
    /// has no row.
    ///
    /// These nest as little as they can: a result or aggregate expression reads
    /// only rows its `WHERE` let through, so a `WHERE` that proves the JSON valid
    /// lets them read it unguarded, and a part of another type adds NULL, which
    /// `group_concat` skips and the reducer reads as no item. A message's parts
    /// gather in id order, the order `part_message_id_id_idx` reads them in, since
    /// an aggregate takes no `ORDER BY` here, and objects are built flat with
    /// `json_set` paths. A step's error is the one exception: a path under
    /// `$.error` would make an empty error of a step that had none, which reads
    /// as a failed step, so the whole error is NULL unless 1.x recorded one.
    static func v1Messages(_ session: String) -> String {
        let role = "json_extract(msg.data, '$.role')"
        let isSummary = "json_type(msg.data, '$.summary') = 'true'"
        let time = "'$.time.created', json_extract(msg.data, '$.time.created'), "
            + "'$.time.completed', json_extract(msg.data, '$.time.completed')"
        let parts = "FROM part p WHERE p.message_id = msg.id AND json_valid(p.data)"
        return """
            v1_seq AS (SELECT id, row_number() OVER (ORDER BY time_created, id) AS seq
                         FROM message WHERE session_id = \(session)),
            session_message AS (SELECT msg.id AS id, msg.session_id AS session_id,
                CASE WHEN \(role) = 'user' THEN CASE WHEN EXISTS (SELECT 1 FROM part p WHERE p.message_id = msg.id
                       AND p.data LIKE '%"type":"compaction"%') THEN 'v1-compaction' ELSE 'user' END
                     WHEN \(role) = 'assistant' AND \(isSummary) THEN 'compaction'
                     WHEN \(role) = 'assistant' THEN 'assistant'
                     ELSE 'v1-' || coalesce(\(role), '') END AS type,
                q.seq AS seq, msg.time_created AS time_created,
                max(msg.time_updated, coalesce((SELECT max(p.time_updated) FROM part p WHERE p.message_id = msg.id), 0))
                  AS time_updated,
                CASE WHEN \(role) = 'user' THEN json_set('{}', '$.text', \(v1Text(synthetic: false)),
                       '$.files', json((SELECT json_group_array(CASE json_extract(p.data, '$.type') WHEN 'file' THEN
                         json_object('name', json_extract(p.data, '$.filename'), 'mime', json_extract(p.data, '$.mime')) END)
                         \(parts))),
                       '$.time.created', msg.time_created)
                     WHEN \(role) = 'assistant' AND \(isSummary) THEN json_set('{}', '$.status', 'completed',
                       '$.summary', \(v1Text(synthetic: true)), \(time))
                     WHEN \(role) = 'assistant' THEN json_set('{}',
                       '$.content', json((SELECT json_group_array(\(v1Item)) \(parts))),
                       '$.finish', json_extract(msg.data, '$.finish'),
                       '$.error', json(CASE WHEN json_type(msg.data, '$.error') = 'object' THEN json_object(
                         'type', replace(json_extract(msg.data, '$.error.name'), 'MessageAbortedError', 'aborted'),
                         'message', json_extract(msg.data, '$.error.data.message')) END), \(time))
                     ELSE json_set('{}', '$.time.created', msg.time_created) END AS data
              FROM message msg JOIN v1_seq q ON q.id = msg.id WHERE json_valid(msg.data))
            """
    }

    /// A message's text parts joined by newlines: a prompt's own, without
    /// the text 1.x adds for an attachment, or every one. A part's JSON keeps a
    /// quote in its text escaped, so only the flag itself matches.
    private static func v1Text(synthetic: Bool) -> String {
        """
        (SELECT group_concat(CASE WHEN json_extract(p.data, '$.type') = 'text'\
        \(synthetic ? "" : #" AND p.data NOT LIKE '%"synthetic":true%'"#) THEN json_extract(p.data, '$.text') END,
          char(10)) FROM part p WHERE p.message_id = msg.id AND json_valid(p.data))
        """
    }

    /// A text, reasoning or tool part as 2's content item, NULL for another
    /// part. A tool's output becomes its one text; its `pending` reads as
    /// running, as 2's `streaming` does.
    private static let v1Item = """
        CASE json_extract(p.data, '$.type')
          WHEN 'tool' THEN json_set('{}', '$.type', 'tool', '$.id', json_extract(p.data, '$.callID'),
            '$.name', json_extract(p.data, '$.tool'),
            '$.state.status', json_extract(p.data, '$.state.status'),
            '$.state.input', json_extract(p.data, '$.state.input'),
            '$.state.error', json_extract(p.data, '$.state.error'),
            '$.state.metadata', json_extract(p.data, '$.state.metadata'),
            '$.state.content[0].type', 'text', '$.state.content[0].text', json_extract(p.data, '$.state.output'),
            '$.time.created', json_extract(p.data, '$.state.time.start'),
            '$.time.completed', json_extract(p.data, '$.state.time.end'))
          WHEN 'reasoning' THEN json_set('{}', '$.type', 'reasoning', '$.text', json_extract(p.data, '$.text'),
            '$.time.created', json_extract(p.data, '$.time.start'),
            '$.time.completed', json_extract(p.data, '$.time.end'))
          WHEN 'text' THEN json_set('{}', '$.type', 'text', '$.text', json_extract(p.data, '$.text')) END
        """
}
