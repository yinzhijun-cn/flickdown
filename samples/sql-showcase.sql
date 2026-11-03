-- 通用 SQL：关键字、字符串、数字和标识符
SELECT `order_id`, customer_name, amount
FROM orders
WHERE status = 'PAID'
  AND amount >= 1250.50
ORDER BY created_at DESC
LIMIT 20;

/* 多行注释：这里的 SELECT、'字符串' 和 123 都属于注释。
   滚动到注释中间时仍保持注释颜色。
*/
CREATE TABLE order_notes (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    order_id BIGINT NOT NULL,
    note VARCHAR(255) DEFAULT '待确认',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

# MySQL 注释与转义
INSERT INTO order_notes (order_id, note)
VALUES (1001, 'It''s ready'),
       (1002, '路径：C:\\logs\\orders'),
       (1003, '第一行说明
第二行中的 SELECT 和 /* 不会变成关键字或注释');

SELECT "column_name", 0xFF, 3.14e2, NULL;
