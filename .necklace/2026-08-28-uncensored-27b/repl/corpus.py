# Compaction test corpus. Each item: a realistic opencode-style transcript with
# embedded checkable facts, and a fact list. A fact survives if ANY of its
# accepted substrings appears in the summary (case-insensitive). Facts are the
# things a handoff MUST keep: file:line, identifiers, numbers, and decisions.
CORPUS = [
{
 "id": "auth-bug",
 "convo": """User: The login flow drops the session on the second request. Find it.
Assistant: The bug is in auth/session.py:142 -- refresh_token() reads the cookie as `sid` but set_cookie writes it as `session_id`, so the lookup misses. I'll rename the read to `session_id`.
User: Do it, and add a test.
Assistant: Done. Renamed the read at auth/session.py:142. Added test_session_persists_across_requests in tests/test_auth.py, which fires two requests and asserts the same user_id survives. The token TTL is 3600 seconds; I left that unchanged. Also noticed refresh_token() swallows a KeyError at line 155 -- flagged but not touched, since you didn't ask.""",
 "facts": [
   ["auth/session.py:142", "session.py:142", "line 142"],
   ["refresh_token"],
   ["sid"],
   ["session_id"],
   ["test_session_persists_across_requests", "test that fires two requests", "persists across requests"],
   ["tests/test_auth.py", "test_auth.py"],
   ["3600", "TTL", "one hour"],
   ["KeyError"],
   ["155", "line 155"],
 ],
},
{
 "id": "perf-decision",
 "convo": """User: The dashboard query takes 4.2 seconds. Speed it up.
Assistant: Profiled it. 3.8s of the 4.2 is a per-row N+1 in reports/aggregate.py -- it queries orders once per customer inside the loop. Two options: (a) a single JOIN with GROUP BY, or (b) a Redis cache keyed by customer_id with a 60s TTL.
User: Which?
Assistant: JOIN. The cache would mask the N+1 rather than fix it, and staleness on financial numbers is worse than 4 seconds. Rewrote it as one query with GROUP BY customer_id at reports/aggregate.py:88. Measured after: 0.31 seconds, so 13x. Left an index recommendation on orders.customer_id -- without it the JOIN is 1.1s instead of 0.31.""",
 "facts": [
   ["4.2", "4.2 second"],
   ["N+1"],
   ["reports/aggregate.py", "aggregate.py"],
   ["JOIN"],
   ["GROUP BY"],
   ["Redis", "cache"],
   ["rejected the cache", "not the cache", "chose join over", "join over the cache", "cache would mask", "instead of the cache", "rather than the cache"],
   ["0.31"],
   ["13x", "13 x", "thirteen"],
   ["orders.customer_id", "index on"],
 ],
},
{
 "id": "deploy-incident",
 "convo": """User: Prod is 500ing after the 14:30 deploy. Triage.
Assistant: The 14:30 deploy shipped commit a3f9c21, which bumped the postgres driver from 2.9 to 3.0. 3.0 defaults sslmode to `require`; our RDS instance has no cert configured, so every connection throws. Rolling back to a3f9c21's parent now.
User: Rolled back?
Assistant: Yes, prod is on commit 7b2e004 and 500s stopped at 14:52. Root cause stands: the driver bump needs sslmode=disable in DATABASE_URL, or a cert on RDS. I filed it as the fix-forward. Error rate peaked at 74% of requests during the 22-minute window.""",
 "facts": [
   ["14:30"],
   ["a3f9c21"],
   ["postgres driver", "postgres", "driver"],
   ["3.0"],
   ["sslmode"],
   ["require"],
   ["RDS"],
   ["7b2e004"],
   ["14:52"],
   ["sslmode=disable", "disable", "cert on RDS"],
   ["74%", "74 %"],
   ["22-minute", "22 minute", "22-min"],
 ],
},
{
 "id": "refactor-scope",
 "convo": """User: Extract the payment logic out of checkout.py into its own module.
Assistant: Moved charge(), refund(), and validate_card() into payments/core.py. checkout.py now imports from it. I did NOT move webhook_handler() -- it's coupled to the Flask request object and moving it would drag the web layer into payments/core.py, which defeats the point. Left it in checkout.py with a comment.
User: Fine. Tests pass?
Assistant: 47 of 48. test_refund_partial fails, but it failed before the refactor too -- it asserts a rounding behavior that changed in the 2.1 release. Unrelated to this change; flagged separately. Everything else green.""",
 "facts": [
   ["charge"],
   ["refund"],
   ["validate_card"],
   ["payments/core.py", "core.py"],
   ["checkout.py"],
   ["webhook_handler"],
   ["Flask"],
   ["did not move webhook", "left webhook", "kept webhook", "not move", "webhook_handler in checkout", "coupled to"],
   ["47 of 48", "47/48", "one test fail", "47 pass"],
   ["test_refund_partial"],
   ["pre-existing", "failed before", "unrelated", "2.1 release", "rounding"],
 ],
},
{
 "id": "api-design",
 "convo": """User: Design the pagination for the /events endpoint.
Assistant: Cursor-based, not offset. Offset pagination double-counts when rows are inserted mid-scroll, and /events is append-heavy. The cursor is the opaque base64 of (created_at, id) so ties on created_at break deterministically by id. Page size defaults to 50, caps at 200. The response carries next_cursor; a null next_cursor means the end.
User: Why base64 the tuple instead of just the id?
Assistant: Because created_at isn't unique -- two events in the same millisecond would let a pure-id cursor skip one when sorting by time. The composite (created_at, id) is a total order; id alone isn't. Encoded so clients treat it as opaque and don't build logic on its contents.""",
 "facts": [
   ["cursor-based", "cursor based", "cursor pagination"],
   ["not offset", "rejected offset", "instead of offset", "offset double", "over offset"],
   ["append-heavy", "append heavy", "insert"],
   ["base64"],
   ["created_at"],
   ["id"],
   ["50"],
   ["200"],
   ["next_cursor"],
   ["null", "None"],
   ["same millisecond", "not unique", "ties", "total order", "composite"],
 ],
},
]
