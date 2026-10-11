\pset format unaligned
\pset tuples_only on
\pset fieldsep ' | '
select case when ok then 'PASS' else 'FAIL' end, name, coalesce(detail, '') from tst.results order by id;
select 'TOTAL ' || count(*) filter (where ok) || ' PASS / ' || count(*) filter (where not ok) || ' FAIL' from tst.results;
