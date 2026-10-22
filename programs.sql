-- ============================================================
--  Stored programs: audit tables, functions, procedures, triggers
--  Target DBMS: MySQL 8.0 or newer
--
--  Blocks are separated by a custom delimiter so the procedure
--  bodies survive. In MySQL Workbench, run the file as it is.
--  The application strips the DELIMITER lines and runs each
--  block on its own.
-- ============================================================

DELIMITER $$

-- ---------- supporting tables ----------

CREATE TABLE IF NOT EXISTS interaction_audit (
    audit_id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    interaction_id   BIGINT      NULL,
    post_id          INT         NOT NULL,
    user_id          INT         NOT NULL,
    interaction_type VARCHAR(10) NOT NULL,
    action           VARCHAR(10) NOT NULL,
    recorded_at      DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_audit_recorded (recorded_at)
) ENGINE = InnoDB$$

CREATE TABLE IF NOT EXISTS post_audit (
    audit_id    BIGINT AUTO_INCREMENT PRIMARY KEY,
    post_id     INT         NOT NULL,
    user_id     INT         NOT NULL,
    topic       VARCHAR(60) NOT NULL,
    action      VARCHAR(10) NOT NULL,
    recorded_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE = InnoDB$$

-- Report tables written by the cursor procedures.
CREATE TABLE IF NOT EXISTS user_engagement_report (
    user_id        INT PRIMARY KEY,
    username       VARCHAR(30)    NOT NULL,
    posts_counted  INT            NOT NULL,
    total_points   DECIMAL(12, 1) NOT NULL,
    best_post_id   INT            NULL,
    best_post_points DECIMAL(10, 1) NULL,
    average_points DECIMAL(10, 1) NOT NULL,
    generated_at   DATETIME       NOT NULL
) ENGINE = InnoDB$$

CREATE TABLE IF NOT EXISTS trending_report (
    report_row   INT AUTO_INCREMENT PRIMARY KEY,
    post_id      INT            NOT NULL,
    author       VARCHAR(30)    NOT NULL,
    topic        VARCHAR(60)    NOT NULL,
    points       DECIMAL(10, 1) NOT NULL,  -- earned inside the window, not lifetime
    window_start DATETIME       NOT NULL,
    window_end   DATETIME       NOT NULL,
    generated_at DATETIME       NOT NULL
) ENGINE = InnoDB$$

-- ---------- functions ----------

DROP FUNCTION IF EXISTS CalculatePostEngagement$$
-- Weighted score for one post: view 0.2, like 1, save 2, comment 2, share 3.
-- Used by both procedures and callable on its own from any query.
CREATE FUNCTION CalculatePostEngagement(p_post_id INT)
RETURNS DECIMAL(10, 1)
READS SQL DATA
BEGIN
    DECLARE v_points DECIMAL(10, 1);

    SELECT COALESCE(SUM(CASE i.interaction_type
                            WHEN 'view'  THEN 0.2
                            WHEN 'like'  THEN 1.0
                            WHEN 'save'  THEN 2.0
                            WHEN 'share' THEN 3.0
                            ELSE 0 END), 0)
      INTO v_points
      FROM interactions i
     WHERE i.post_id = p_post_id;

    SET v_points = v_points + (SELECT COUNT(*) * 2.0 FROM comments c WHERE c.post_id = p_post_id);

    RETURN ROUND(v_points, 1);
END$$

DROP FUNCTION IF EXISTS CalculateUserEngagement$$
-- Total points a creator has earned across everything they have published.
CREATE FUNCTION CalculateUserEngagement(p_user_id INT)
RETURNS DECIMAL(12, 1)
READS SQL DATA
BEGIN
    DECLARE v_total DECIMAL(12, 1) DEFAULT 0;

    SELECT COALESCE(SUM(CalculatePostEngagement(p.post_id)), 0)
      INTO v_total
      FROM posts p
     WHERE p.user_id = p_user_id;

    RETURN ROUND(v_total, 1);
END$$

DROP FUNCTION IF EXISTS CalculateWindowEngagement$$
-- Points a post earned from activity that happened BETWEEN two moments,
-- rather than over its whole life. This is what "trending" means: a post
-- from last year is trending if people are reacting to it this week.
-- Same weights as CalculatePostEngagement.
CREATE FUNCTION CalculateWindowEngagement(p_post_id INT, p_start DATETIME, p_end DATETIME)
RETURNS DECIMAL(10, 1)
READS SQL DATA
BEGIN
    DECLARE v_points DECIMAL(10, 1);

    SELECT COALESCE(SUM(CASE i.interaction_type
                            WHEN 'view'  THEN 0.2
                            WHEN 'like'  THEN 1.0
                            WHEN 'save'  THEN 2.0
                            WHEN 'share' THEN 3.0
                            ELSE 0 END), 0)
      INTO v_points
      FROM interactions i
     WHERE i.post_id = p_post_id
       AND i.created_at BETWEEN p_start AND p_end;

    SET v_points = v_points + (SELECT COUNT(*) * 2.0
                                 FROM comments c
                                WHERE c.post_id = p_post_id
                                  AND c.created_at BETWEEN p_start AND p_end);

    RETURN ROUND(v_points, 1);
END$$

-- ---------- procedures (both use cursors) ----------

DROP PROCEDURE IF EXISTS GenerateUserEngagementReport$$
-- Walks one creator's posts row by row with a cursor, scores each post with
-- CalculatePostEngagement, and stores a creator-level summary.
CREATE PROCEDURE GenerateUserEngagementReport(IN p_user_id INT)
BEGIN
    DECLARE v_done          INT DEFAULT 0;
    DECLARE v_post_id       INT;
    DECLARE v_points        DECIMAL(10, 1);
    DECLARE v_total         DECIMAL(12, 1) DEFAULT 0;
    DECLARE v_count         INT DEFAULT 0;
    DECLARE v_best_post     INT DEFAULT NULL;
    DECLARE v_best_points   DECIMAL(10, 1) DEFAULT 0;
    DECLARE v_username      VARCHAR(30);

    DECLARE post_cursor CURSOR FOR
        SELECT post_id FROM posts WHERE user_id = p_user_id ORDER BY post_id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    SELECT username INTO v_username FROM users WHERE user_id = p_user_id;
    IF v_username IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No user with that id';
    END IF;

    OPEN post_cursor;
    read_loop: LOOP
        FETCH post_cursor INTO v_post_id;
        IF v_done = 1 THEN
            LEAVE read_loop;
        END IF;

        SET v_points = CalculatePostEngagement(v_post_id);
        SET v_total = v_total + v_points;
        SET v_count = v_count + 1;

        IF v_points > v_best_points THEN
            SET v_best_points = v_points;
            SET v_best_post = v_post_id;
        END IF;
    END LOOP;
    CLOSE post_cursor;

    REPLACE INTO user_engagement_report
        (user_id, username, posts_counted, total_points, best_post_id, best_post_points, average_points, generated_at)
    VALUES
        (p_user_id, v_username, v_count, v_total, v_best_post, v_best_points,
         ROUND(IF(v_count = 0, 0, v_total / v_count), 1), NOW());

    SELECT * FROM user_engagement_report WHERE user_id = p_user_id;
END$$

DROP PROCEDURE IF EXISTS GenerateTrendingPostReport$$
-- Walks every post that saw activity in the window with a cursor, scores it
-- on that window's interactions and comments only, and rebuilds the report.
--
-- Note what the cursor selects: posts with activity BETWEEN the two dates,
-- not posts created between them. An older post that people are reacting to
-- this week is trending; a post published this week that nobody touched is
-- not. This matches the "Trending in the last 7 days" query in the Query lab.
CREATE PROCEDURE GenerateTrendingPostReport(IN p_start DATETIME, IN p_end DATETIME, IN p_limit INT)
BEGIN
    DECLARE v_done     INT DEFAULT 0;
    DECLARE v_post_id  INT;
    DECLARE v_author   VARCHAR(30);
    DECLARE v_topic    VARCHAR(60);
    DECLARE v_points   DECIMAL(10, 1);

    DECLARE window_cursor CURSOR FOR
        SELECT p.post_id, u.username, p.topic
          FROM posts p
          JOIN users u ON u.user_id = p.user_id
         WHERE EXISTS (SELECT 1 FROM interactions i
                        WHERE i.post_id = p.post_id
                          AND i.created_at BETWEEN p_start AND p_end)
            OR EXISTS (SELECT 1 FROM comments c
                        WHERE c.post_id = p.post_id
                          AND c.created_at BETWEEN p_start AND p_end)
         ORDER BY p.post_id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    DELETE FROM trending_report;

    OPEN window_cursor;
    scan_loop: LOOP
        FETCH window_cursor INTO v_post_id, v_author, v_topic;
        IF v_done = 1 THEN
            LEAVE scan_loop;
        END IF;

        SET v_points = CalculateWindowEngagement(v_post_id, p_start, p_end);

        IF v_points > 0 THEN
            INSERT INTO trending_report
                (post_id, author, topic, points, window_start, window_end, generated_at)
            VALUES
                (v_post_id, v_author, v_topic, v_points, p_start, p_end, NOW());
        END IF;
    END LOOP;
    CLOSE window_cursor;

    SELECT post_id, author, topic, points AS points_in_window,
           RANK() OVER (ORDER BY points DESC) AS trend_rank
      FROM trending_report
     ORDER BY points DESC
     LIMIT p_limit;
END$$

-- ---------- triggers ----------

DROP TRIGGER IF EXISTS trg_no_self_engagement$$
-- Integrity: nobody boosts their own post. This needs a lookup in another
-- table, which a CHECK constraint cannot do, so it has to be a trigger.
CREATE TRIGGER trg_no_self_engagement
BEFORE INSERT ON interactions
FOR EACH ROW
BEGIN
    DECLARE v_author INT;

    SELECT user_id INTO v_author FROM posts WHERE post_id = NEW.post_id;

    IF v_author = NEW.user_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A user cannot interact with their own post';
    END IF;
END$$

DROP TRIGGER IF EXISTS trg_interaction_audit$$
-- Auditing: every engagement event is recorded with the moment it arrived.
CREATE TRIGGER trg_interaction_audit
AFTER INSERT ON interactions
FOR EACH ROW
BEGIN
    INSERT INTO interaction_audit (interaction_id, post_id, user_id, interaction_type, action, recorded_at)
    VALUES (NEW.interaction_id, NEW.post_id, NEW.user_id, NEW.interaction_type, 'insert', NOW());
END$$

DROP TRIGGER IF EXISTS trg_post_delete_audit$$
-- Auditing: a deleted post takes its comments and interactions with it, so
-- keep a record of what was removed and when.
CREATE TRIGGER trg_post_delete_audit
AFTER DELETE ON posts
FOR EACH ROW
BEGIN
    INSERT INTO post_audit (post_id, user_id, topic, action, recorded_at)
    VALUES (OLD.post_id, OLD.user_id, OLD.topic, 'delete', NOW());
END$$

DELIMITER ;
