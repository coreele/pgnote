```sql
DROP TABLE IF EXISTS tb_test;

CREATE TABLE tb_test (
    id  INT,
    val INT
);

INSERT INTO tb_test VALUES
(1, 10),
(2, 20),
(3, 30);

CREATE OR REPLACE FUNCTION trg_row_after_update()
RETURNS trigger AS $$
BEGIN
    RAISE NOTICE 'ROW AFTER: id=%, old=%, new=%',
        OLD.id, OLD.val, NEW.val;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_stmt_after_update()
RETURNS trigger AS $$
BEGIN
    RAISE NOTICE 'STATEMENT AFTER trigger fired';
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_deferred_constraint()
RETURNS trigger AS $$
BEGIN
    RAISE NOTICE 'DEFERRED CONSTRAINT TRIGGER fired (id=%)', NEW.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 行级 AFTER UPDATE
CREATE TRIGGER trg_row_after
AFTER UPDATE ON tb_test
FOR EACH ROW
EXECUTE FUNCTION trg_row_after_update();

-- 语句级 AFTER UPDATE
CREATE TRIGGER trg_stmt_after
AFTER UPDATE ON tb_test
FOR EACH STATEMENT
EXECUTE FUNCTION trg_stmt_after_update();

CREATE CONSTRAINT TRIGGER trg_deferred
AFTER UPDATE ON tb_test
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION trg_deferred_constraint();


UPDATE tb_test SET val = val + 1;
```