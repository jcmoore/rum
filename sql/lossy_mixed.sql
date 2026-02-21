CREATE EXTENSION rum;
CREATE TABLE test_table (
	id bigint,
	folder bigint,
	time bigint,
	tags int4[]
);

CREATE INDEX test_idx
ON test_table USING rum(folder, tags rum_anyarray_addon_ops, time)
WITH (attach = 'time', to = 'tags', order_by_attach = TRUE);

INSERT INTO test_table (id, folder, time, tags) VALUES
	(1, 10, 100, '{1,10}'),
	(2, 20, 200, '{2,20}'),
	(3, 10, 300, '{1,30}'),
	(4, 20, 400, '{2,40}'),
	(5, 20, 60,  '{2,50}'),
	(6, 10, 40,  '{1,60}'),
	(7, 20, 50,  '{2,70}'),
	(8, 10, 30,  '{1,80}');

EXPLAIN (costs off)
SELECT *
FROM test_table
WHERE tags && '{1}'::int4[]
	AND folder = 10::bigint;

SELECT *
FROM test_table
WHERE tags && '{1}'::int4[]
	AND folder = 10::bigint;

EXPLAIN (costs off)
SELECT *
FROM test_table
WHERE tags && '{1}'::int4[]
	AND folder = 10::bigint
ORDER BY time <=| 500::bigint;

SELECT *
FROM test_table
WHERE tags && '{1}'::int4[]
	AND folder = 10::bigint
ORDER BY time <=| 500::bigint;
