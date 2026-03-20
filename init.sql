-- ============================================================
--  Pharmaceutical Inventory Management System
--  Database : pharma_db
--  File     : init.sql
-- ============================================================

-- Drop in reverse dependency order (safe re-run)
DROP TABLE IF EXISTS stock;
DROP TABLE IF EXISTS permission;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS medicines;
DROP TABLE IF EXISTS company;
DROP TABLE IF EXISTS roles;

-- Drop views
DROP VIEW IF EXISTS v_low_stock;
DROP VIEW IF EXISTS v_expiry_alert;
DROP VIEW IF EXISTS v_stock_summary;

-- Drop triggers
DROP TRIGGER IF EXISTS trg_low_stock_check;

-- Drop procedures
DROP PROCEDURE IF EXISTS sp_restock;
DROP PROCEDURE IF EXISTS sp_dispense_stock;


-- ============================================================
--  TABLE 1 : roles
--  Lookup table — defines access levels in the system
-- ============================================================
CREATE TABLE roles (
    role_id     INT          AUTO_INCREMENT PRIMARY KEY,
    role_name   VARCHAR(50)  NOT NULL UNIQUE
);


-- ============================================================
--  TABLE 2 : company
--  Lookup table — medicine suppliers
-- ============================================================
CREATE TABLE company (
    com_id    INT           AUTO_INCREMENT PRIMARY KEY,
    com_name  VARCHAR(100)  NOT NULL UNIQUE
);


-- ============================================================
--  TABLE 3 : users
--  System users — admins, managers, viewers
-- ============================================================
CREATE TABLE users (
    user_id        INT          AUTO_INCREMENT PRIMARY KEY,
    user_name      VARCHAR(100) NOT NULL,
    user_email     VARCHAR(150) NOT NULL UNIQUE,
    user_password  VARCHAR(255) NOT NULL,
    role_id        INT          NOT NULL,
    created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT fk_users_role
        FOREIGN KEY (role_id)
        REFERENCES roles(role_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
);


-- ============================================================
--  TABLE 4 : permission
--  Defines what each role can do in each module
-- ============================================================
CREATE TABLE permission (
    per_id       INT          AUTO_INCREMENT PRIMARY KEY,
    per_role_id  INT          NOT NULL,
    per_name     VARCHAR(100) NOT NULL,
    per_module   VARCHAR(100) NOT NULL,

    CONSTRAINT fk_permission_role
        FOREIGN KEY (per_role_id)
        REFERENCES roles(role_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);


-- ============================================================
--  TABLE 5 : medicines
--  Medicine catalogue — what each medicine is
-- ============================================================
CREATE TABLE medicines (
    mdcn_id            INT          AUTO_INCREMENT PRIMARY KEY,
    mdcn_name          VARCHAR(150) NOT NULL UNIQUE,
    mdcn_type          ENUM(
                           'tablet',
                           'capsule',
                           'syrup',
                           'injection',
                           'ointment',
                           'drops',
                           'powder'
                       )            NOT NULL,
    mdcn_desc          TEXT,
    mdcn_dosage_value  FLOAT        NOT NULL CHECK (mdcn_dosage_value > 0),
    mdcn_dosage_unit   ENUM(
                           'mg',
                           'mcg',
                           'g',
                           'ml',
                           'l',
                           'IU'
                       )            NOT NULL,
    created_at         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ============================================================
--  TABLE 6 : stock
--  Core table — one row per batch
--  Same medicine from same company can have multiple rows
--  each with a different expiry date and price
-- ============================================================
CREATE TABLE stock (
    stk_id             INT            AUTO_INCREMENT PRIMARY KEY,
    mdcn_id            INT            NOT NULL,
    com_id             INT            NOT NULL,
    user_id            INT            NOT NULL,
    stk_quantity       INT            NOT NULL DEFAULT 0
                                      CHECK (stk_quantity >= 0),
    stk_reorder_level  INT            NOT NULL DEFAULT 10
                                      CHECK (stk_reorder_level > 0),
    stk_expiry_date    DATE           NOT NULL,
    stk_price          DECIMAL(10,2)  NOT NULL CHECK (stk_price > 0),
    created_at         TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
                                      ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT fk_stock_medicine
        FOREIGN KEY (mdcn_id)
        REFERENCES medicines(mdcn_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE,

    CONSTRAINT fk_stock_company
        FOREIGN KEY (com_id)
        REFERENCES company(com_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE,

    CONSTRAINT fk_stock_user
        FOREIGN KEY (user_id)
        REFERENCES users(user_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
);


-- ============================================================
--  INDEXES
-- ============================================================
CREATE INDEX idx_mdcn_name   ON medicines(mdcn_name);
CREATE INDEX idx_stk_expiry  ON stock(stk_expiry_date);
CREATE INDEX idx_stk_mdcn_id ON stock(mdcn_id);
CREATE INDEX idx_stk_com_id  ON stock(com_id);


-- ============================================================
--  VIEW 1 : v_low_stock
--  All batches where quantity is at or below reorder level
-- ============================================================
CREATE VIEW v_low_stock AS
SELECT
    s.stk_id,
    m.mdcn_name,
    m.mdcn_type,
    c.com_name,
    s.stk_quantity,
    s.stk_reorder_level,
    s.stk_expiry_date,
    s.stk_price,
    (s.stk_reorder_level - s.stk_quantity) AS units_needed
FROM stock s
JOIN medicines m ON s.mdcn_id = m.mdcn_id
JOIN company  c ON s.com_id   = c.com_id
WHERE s.stk_quantity <= s.stk_reorder_level;


-- ============================================================
--  VIEW 2 : v_expiry_alert
--  All batches expiring within the next 30 days
-- ============================================================
CREATE VIEW v_expiry_alert AS
SELECT
    s.stk_id,
    m.mdcn_name,
    m.mdcn_type,
    c.com_name,
    s.stk_quantity,
    s.stk_expiry_date,
    DATEDIFF(s.stk_expiry_date, CURDATE()) AS days_to_expiry
FROM stock s
JOIN medicines m ON s.mdcn_id = m.mdcn_id
JOIN company  c ON s.com_id   = c.com_id
WHERE s.stk_expiry_date <= DATE_ADD(CURDATE(), INTERVAL 30 DAY)
  AND s.stk_expiry_date >= CURDATE();


-- ============================================================
--  VIEW 3 : v_stock_summary
--  Dashboard — total quantity and value per medicine
--  across all batches and companies
-- ============================================================
CREATE VIEW v_stock_summary AS
SELECT
    m.mdcn_id,
    m.mdcn_name,
    m.mdcn_type,
    SUM(s.stk_quantity)               AS total_quantity,
    SUM(s.stk_quantity * s.stk_price) AS total_stock_value,
    MIN(s.stk_expiry_date)            AS nearest_expiry,
    COUNT(s.stk_id)                   AS total_batches
FROM medicines m
LEFT JOIN stock s ON m.mdcn_id = s.mdcn_id
GROUP BY m.mdcn_id, m.mdcn_name, m.mdcn_type;


-- ============================================================
--  TRIGGER : trg_low_stock_check
--  Fires after every UPDATE on stock
--  Warns if quantity drops to or below reorder level
-- ============================================================
DELIMITER $$

CREATE TRIGGER trg_low_stock_check
AFTER UPDATE ON stock
FOR EACH ROW
BEGIN
    IF NEW.stk_quantity <= NEW.stk_reorder_level THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'WARNING: Stock quantity has reached or fallen below reorder level.';
    END IF;
END$$

DELIMITER ;


-- ============================================================
--  PROCEDURE 1 : sp_restock
--
--  New batch arriving = INSERT a new row
--  Never UPDATE an existing batch on restock
--  because every batch has its own expiry date and price
--
--  Parameters:
--    p_mdcn_id     → which medicine
--    p_com_id      → which supplier
--    p_user_id     → who is adding this batch
--    p_quantity    → how many units in this batch
--    p_expiry_date → expiry date of this specific batch
--    p_price       → supplier price for this batch
--    p_reorder_lvl → minimum threshold before alert
-- ============================================================
DELIMITER $$

CREATE PROCEDURE sp_restock(
    IN p_mdcn_id      INT,
    IN p_com_id       INT,
    IN p_user_id      INT,
    IN p_quantity     INT,
    IN p_expiry_date  DATE,
    IN p_price        DECIMAL(10,2),
    IN p_reorder_lvl  INT
)
BEGIN
    -- Validate quantity
    IF p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ERROR: Restock quantity must be greater than zero.';
    END IF;

    -- Validate price
    IF p_price <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ERROR: Price must be greater than zero.';
    END IF;

    -- Validate expiry date is in the future
    IF p_expiry_date <= CURDATE() THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ERROR: Expiry date must be a future date.';
    END IF;

    -- Validate medicine exists
    IF NOT EXISTS (SELECT 1 FROM medicines WHERE mdcn_id = p_mdcn_id) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ERROR: Medicine does not exist.';
    END IF;

    -- Validate company exists
    IF NOT EXISTS (SELECT 1 FROM company WHERE com_id = p_com_id) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ERROR: Company does not exist.';
    END IF;

    -- Insert new batch as its own row
    INSERT INTO stock (
        mdcn_id,
        com_id,
        user_id,
        stk_quantity,
        stk_reorder_level,
        stk_expiry_date,
        stk_price
    ) VALUES (
        p_mdcn_id,
        p_com_id,
        p_user_id,
        p_quantity,
        p_reorder_lvl,
        p_expiry_date,
        p_price
    );

    SELECT 'New stock batch added successfully.' AS message;
END$$

DELIMITER ;


-- ============================================================
--  PROCEDURE 2 : sp_dispense_stock
--
--  Medicine going out = UPDATE existing batch (FEFO)
--  FEFO = First Expiry First Out
--  Always dispense from the batch expiring soonest first
--  Only considers batches with quantity > 0
--  and expiry date in the future
--
--  Parameters:
--    p_mdcn_id  → which medicine to dispense
--    p_com_id   → from which supplier batch
--    p_quantity → how many units to dispense
-- ============================================================
DELIMITER $$

CREATE PROCEDURE sp_dispense_stock(
    IN p_mdcn_id   INT,
    IN p_com_id    INT,
    IN p_quantity  INT
)
BEGIN
    DECLARE v_stk_id      INT;
    DECLARE v_current_qty INT;
    DECLARE v_remaining   INT;

    -- Validate dispense quantity
    IF p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ERROR: Dispense quantity must be greater than zero.';
    END IF;

    -- Validate medicine exists
    IF NOT EXISTS (SELECT 1 FROM medicines WHERE mdcn_id = p_mdcn_id) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ERROR: Medicine does not exist.';
    END IF;

    -- Find batch expiring soonest (FEFO)
    -- Only valid batches: quantity > 0, not expired
    SELECT stk_id, stk_quantity
    INTO   v_stk_id, v_current_qty
    FROM   stock
    WHERE  mdcn_id        = p_mdcn_id
      AND  com_id         = p_com_id
      AND  stk_quantity   > 0
      AND  stk_expiry_date > CURDATE()
    ORDER BY stk_expiry_date ASC
    LIMIT 1;    -- Return only the first row from the result set

    -- No valid batch found
    IF v_stk_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ERROR: No valid stock found for this medicine and supplier.';
    END IF;

    -- Insufficient quantity in nearest expiry batch
    IF v_current_qty < p_quantity THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'ERROR: Insufficient stock in the nearest expiry batch.';
    END IF;

    -- Dispense from nearest expiry batch
    UPDATE stock
    SET    stk_quantity = stk_quantity - p_quantity
    WHERE  stk_id = v_stk_id;

    SET v_remaining = v_current_qty - p_quantity;

    SELECT
        'Stock dispensed successfully.' AS message,
        v_stk_id                        AS batch_id,
        v_remaining                     AS remaining_quantity;
END$$

DELIMITER ;


-- ============================================================
--  SEED DATA
-- ============================================================

-- Roles
INSERT INTO roles (role_name) VALUES
    ('admin'),
    ('manager'),
    ('viewer');

-- Permissions
INSERT INTO permission (per_role_id, per_name, per_module) VALUES
    (1, 'full_access', 'stock'),
    (1, 'full_access', 'medicines'),
    (1, 'full_access', 'users'),
    (2, 'read_write',  'stock'),
    (2, 'read_only',   'medicines'),
    (3, 'read_only',   'stock'),
    (3, 'read_only',   'medicines');

-- Companies
INSERT INTO company (com_name) VALUES
    ('Sun Pharma'),
    ('Cipla'),
    ('Dr. Reddys');

-- Users (passwords must be hashed via bcrypt in production)
INSERT INTO users (user_name, user_email, user_password, role_id) VALUES
    ('Admin User',   'admin@pharma.com',   'hashed_password_1', 1),
    ('Manager User', 'manager@pharma.com', 'hashed_password_2', 2),
    ('Viewer User',  'viewer@pharma.com',  'hashed_password_3', 3);

-- Medicines
INSERT INTO medicines (mdcn_name, mdcn_type, mdcn_desc, mdcn_dosage_value, mdcn_dosage_unit) VALUES
    ('Paracetamol',  'tablet',  'Pain reliever and fever reducer', 500, 'mg'),
    ('Ibuprofen',    'tablet',  'Anti-inflammatory pain reliever', 400, 'mg'),
    ('Amoxicillin',  'capsule', 'Broad spectrum antibiotic',       250, 'mg'),
    ('Cetirizine',   'tablet',  'Antihistamine for allergies',      10, 'mg'),
    ('Azithromycin', 'tablet',  'Antibiotic for infections',       500, 'mg');

-- Stock batches
-- Multiple batches per medicine to demonstrate FEFO
INSERT INTO stock (mdcn_id, com_id, user_id, stk_quantity, stk_reorder_level, stk_expiry_date, stk_price) VALUES
    -- Paracetamol: 2 batches from different companies, different expiry
    (1, 1, 1, 500, 50, '2026-12-01', 2.50),
    (1, 2, 1, 200, 50, '2027-03-01', 2.75),
    -- Ibuprofen: low stock to trigger alert
    (2, 1, 2,  15, 30, '2026-08-01', 5.00),
    -- Amoxicillin
    (3, 3, 2, 100, 20, '2026-06-15', 8.00),
    -- Cetirizine: low stock + expiring soon
    (4, 2, 1,   8, 25, '2026-04-10', 3.50),
    -- Azithromycin: 2 batches same company, different expiry and price
    (5, 1, 2,  50, 15, '2026-05-20', 12.00),
    (5, 1, 2,  80, 15, '2027-01-20', 12.50);

-- ============================================================
--  END OF init.sql
-- ============================================================