import Foundation
import VRCCore

/// The statement splitter decides how a migration reaches a private Aurora
/// cluster: the Data API takes one statement at a time, so a splitter that
/// mis-cuts a function body leaves a half-built schema. It had exactly that
/// bug — no dollar-quote tracking — and shredded one `CREATE FUNCTION` into
/// five "statements".
public enum SQLScannerTests {

    static func split(_ sql: String) -> [String] { SQLScanner.splitStatements(sql) }

    public static var cases: [TestCase] { [

        TestCase(group: "SQL scanner",
                 name: "a dollar-quoted function body is one statement") { expect in
            let sql = """
            CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$
            BEGIN
                PERFORM 1;
                RETURN 2;
            END;
            $$;
            CREATE TABLE t (x int);
            """
            let parts = split(sql)
            expect.equal(parts.count, 2, "the body's semicolons are not terminators")
            expect.ok(parts[0].contains("RETURN 2"), "the body survived intact")
            expect.ok(parts[0].hasSuffix("$$"), "including its closing marker")
        },

        TestCase(group: "SQL scanner", name: "a tagged dollar quote is handled") { expect in
            let sql = """
            CREATE FUNCTION g() RETURNS void LANGUAGE plpgsql AS $body$
            BEGIN
                RAISE EXCEPTION 'no; really';
            END;
            $body$;
            SELECT 1;
            """
            let parts = split(sql)
            expect.equal(parts.count, 2)
            expect.ok(parts[0].contains("$body$"), "the tag is preserved")
        },

        TestCase(group: "SQL scanner",
                 name: "nested quoting inside a body does not end it early") { expect in
            let sql = """
            CREATE FUNCTION h() RETURNS void LANGUAGE plpgsql AS $$
            BEGIN
                EXECUTE 'UPDATE t SET note = ''a;b'' WHERE x = 1';
                -- a comment with ; in it
                /* and a block comment; too */
            END;
            $$;
            """
            expect.equal(split(sql).count, 1)
        },

        TestCase(group: "SQL scanner",
                 name: "a lone dollar sign is not a dollar quote") { expect in
            // `$1` and a bare `$` must not start a quoted region, or the rest
            // of the file would be swallowed.
            let sql = "SELECT cost$ FROM prices; SELECT 2;"
            expect.equal(split(sql).count, 2)
        },

        TestCase(group: "SQL scanner",
                 name: "semicolons in literals and comments are not terminators") { expect in
            let sql = """
            INSERT INTO t (note) VALUES ('one; two');
            -- trailing; comment
            SELECT 'it''s; fine';
            """
            expect.equal(split(sql).count, 2)
        },

        TestCase(group: "SQL scanner",
                 name: "every statement in the real migrations is balanced") { expect in
            // The property the migration runner refuses to proceed without: an
            // unbalanced $$ count means a body was cut in half.
            for path in ["Migrations/postgres/010_repository_schema.sql",
                         "Migrations/postgres/011_safety.sql"] {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    expect.fail("cannot read \(path)"); continue
                }
                let parts = split(text)
                expect.ok(parts.count > 1, "\(path) split into \(parts.count) statements")
                let unbalanced = parts.filter {
                    $0.components(separatedBy: "$$").count % 2 == 0
                }
                expect.equal(unbalanced.count, 0,
                             "\(path): \(unbalanced.count) statement(s) with unbalanced $$")
            }
        },

        TestCase(group: "SQL scanner",
                 name: "placeholder rewriting also respects dollar quotes") { expect in
            let rewritten = SQLScanner.rewritePlaceholders(
                "CREATE FUNCTION k() RETURNS void AS $$ BEGIN RAISE NOTICE 'why?'; END; $$; "
                + "SELECT * FROM t WHERE x = ?")
            expect.equal(rewritten.placeholderCount, 1,
                         "the ? inside the body is not a placeholder")
            expect.ok(rewritten.sql.contains("'why?'"), "and the literal is untouched")
        },
    ] }
}
