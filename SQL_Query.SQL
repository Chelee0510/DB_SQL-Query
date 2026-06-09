-- =========================================================================
-- 1. 飼主與寵物管理 (Owners & PetBase) *櫃台人員負責
-- =========================================================================

-- [Create] 新增飼主與寵物

START TRANSACTION;
-- 新增飼主
INSERT INTO Owners (Full_Name, Phone_Number, Email_Address, Physical_Address, Is_Anonymized) 
VALUES (:full_name, :phone_number, :email, :address, FALSE);

-- 獲取自動生成的 ID
SET @new_owner_id = LAST_INSERT_ID();

-- 綁定 Owner_ID 新增寵物
INSERT INTO PetBase (Owner_ID, Pet_Name, Species_Type, Breed_Name, Birth_Date, Current_Weight) 
VALUES (@new_owner_id, :pet_name, :species, :breed, :birth_date, :weight);
COMMIT;


-- [Read] 條件查詢飼主與寵物 *用電話號碼進行查詢

SELECT 
    o.Owner_ID, o.Full_Name, o.Phone_Number, o.Email_Address,
    p.Pet_ID, p.Pet_Name, p.Species_Type, p.Current_Weight,
    TIMESTAMPDIFF(YEAR, p.Birth_Date, CURDATE()) AS Age
FROM Owners o
LEFT JOIN PetBase p ON o.Owner_ID = p.Owner_ID
WHERE o.Phone_Number = :search_phone 
  AND o.Is_Anonymized = FALSE;


-- [Update] 修改飼主與寵物資料

UPDATE Owners 
SET Email_Address = :new_email, Physical_Address = :new_address 
WHERE Owner_ID = :owner_id;

UPDATE PetBase 
SET Current_Weight = :new_weight 
WHERE Pet_ID = :pet_id;


-- [Delete] 匿名化客戶資料（透過 UUID 避免聯絡電話發生 UNIQUE 鍵值衝突）

UPDATE Owners 
SET Full_Name = 'Deleted User', 
    Phone_Number = CONCAT('deleted-', Owner_ID, '-', UUID()), 
    Email_Address = NULL, 
    Physical_Address = NULL, 
    Is_Anonymized = TRUE
WHERE Owner_ID = :owner_id;


-- =========================================================================
-- 2. 預約排程 (Appointments) *櫃台人員負責
-- =========================================================================

-- [Create] 預約(有避免時段重複機制)

START TRANSACTION;
-- 檢測時段衝突並鎖定該條件行
SELECT COUNT(*) INTO @conflict 
FROM Appointments 
WHERE Doc_Staff_ID = :doc_id 
  AND Scheduled_Time = :scheduled_time 
  AND Appt_Status IN (0, 1) FOR UPDATE;

-- 若無時段衝突則寫入
INSERT INTO Appointments (Pet_ID, Doc_Staff_ID, Scheduled_Time, Appt_Status)
SELECT :pet_id, :doc_id, :scheduled_time, 0
FROM DUAL WHERE @conflict = 0;
COMMIT;


-- [Read] 查詢特定醫師在給定日期的預約

SELECT a.Appointment_ID, a.Scheduled_Time, a.Appt_Status, p.Pet_Name
FROM Appointments a
JOIN PetBase p ON a.Pet_ID = p.Pet_ID
WHERE a.Doc_Staff_ID = :doc_id 
  AND DATE(a.Scheduled_Time) = :target_date;


-- [Update] 更改預約時間

UPDATE Appointments 
SET Scheduled_Time = :new_time 
WHERE Appointment_ID = :appt_id;


-- [Delete] 取消預約 (狀態更新)

UPDATE Appointments 
SET Appt_Status = 2 
WHERE Appointment_ID = :appt_id;


-- =========================================================================
-- 3. 人員與權限管理 (Staff & Doctors) *管理人員負責
-- =========================================================================


-- [Create] 新增員工與醫師

START TRANSACTION;
INSERT INTO Staff (Staff_Name, Role_Level, Status_Active, Salary) 
VALUES (:staff_name, :role_level, TRUE, :salary);

SET @new_staff_id = LAST_INSERT_ID();

-- 判斷：若應用程式傳入的 :role_level 為 3 (醫師)，才執行以下指令
INSERT INTO Doctors (Staff_ID, License_Number, Specialty) 
VALUES (@new_staff_id, :license_number, :specialty);
COMMIT;


-- [Read] 依狀態與職級查詢員工

SELECT s.Staff_ID, s.Staff_Name, s.Role_Level, d.License_Number, d.Specialty
FROM Staff s
LEFT JOIN Doctors d ON s.Staff_ID = d.Staff_ID
WHERE s.Status_Active = :is_active 
  AND s.Role_Level = :role_level;


-- [Update] 調整員工薪資或職務

UPDATE Staff 
SET Salary = :new_salary, Role_Level = :new_role 
WHERE Staff_ID = :staff_id;


-- [Delete] 停用離職員工 (使用update記成Status_Active = FALSE)

UPDATE Staff 
SET Status_Active = FALSE 
WHERE Staff_ID = :staff_id;


-- =========================================================================
-- 4. 服務目錄與庫存模組 (Catalog_Items) *管理人員負責
-- =========================================================================


-- [Create] 新增醫療服務或庫存項目

INSERT INTO Catalog_Items (Item_Name, Item_Category, Current_Price, Stock_Quantity, Is_Discontinued) 
VALUES (:item_name, :category, :price, :stock_qty, FALSE);


-- [Read] 查詢低於安全庫存量的藥品

SELECT Item_ID, Item_Name, Stock_Quantity 
FROM Catalog_Items 
WHERE Item_Category = 1 
  AND Is_Discontinued = FALSE 
  AND Stock_Quantity < :safe_threshold;


-- [Update] 價格更新與扣減庫存

-- 更改價格
UPDATE Catalog_Items 
SET Current_Price = :new_price 
WHERE Item_ID = :item_id;


-- 庫存扣減
START TRANSACTION;
SELECT Stock_Quantity INTO @stock 
FROM Catalog_Items 
WHERE Item_ID = :item_id FOR UPDATE;

UPDATE Catalog_Items 
SET Stock_Quantity = Stock_Quantity - :reduce_qty 
WHERE Item_ID = :item_id AND @stock >= :reduce_qty;
COMMIT;


-- [Delete] 下架停產項目

UPDATE Catalog_Items 
SET Is_Discontinued = TRUE 
WHERE Item_ID = :item_id;


-- =========================================================================
-- 5. 病歷與治療明細 (Medical_Records & Treatment_Details) *醫生負責
-- =========================================================================


-- [Create] 建立病歷並開立處方

-- 初始化病歷主檔
INSERT INTO Medical_Records (Appointment_ID, Consultation_Date, Clinical_Notes, Final_Diagnosis, Record_Locked) 
VALUES (:appt_id, CURDATE(), :notes, :diagnosis, FALSE);

SET @record_id = LAST_INSERT_ID();

-- 新增明細 (Historical_Price 傳 0，交由trigger代入實際價格)
INSERT INTO Treatment_Details (Record_ID, Item_ID, Historical_Price, Numeric_Value, Polymorphic_Text1, Polymorphic_Text2) 
VALUES (:record_id, :item_id, 0, :numeric_value, :text1, :text2);


-- [Read] 調閱特定病歷內容與明細

SELECT mr.Clinical_Notes, mr.Final_Diagnosis, 
       c.Item_Name, td.Numeric_Value, td.Polymorphic_Text1, td.Polymorphic_Text2
FROM Medical_Records mr
JOIN Treatment_Details td ON mr.Record_ID = td.Record_ID
JOIN Catalog_Items c ON td.Item_ID = c.Item_ID
WHERE mr.Record_ID = :record_id;


-- [Update] 修改臨床筆記與鎖定病歷

UPDATE Medical_Records 
SET Clinical_Notes = :new_notes, 
    Final_Diagnosis = :new_diagnosis,
    Record_Locked = :is_locked
WHERE Record_ID = :record_id;


-- [Delete] 刪除開錯的治療明細（僅限於病歷鎖定前執行，刪除後trigger會更新帳單）

DELETE FROM Treatment_Details 
WHERE Detail_ID = :detail_id AND Record_ID = :record_id;


-- =========================================================================
-- 6. 帳單收銀 (Invoices)
-- =========================================================================


-- [Create] 初始化帳單

INSERT INTO Invoices (Record_ID, Total_Billed, Payment_Status) 
VALUES (:record_id, 0.00, 0);


-- [Read] 調閱特定狀態的帳單

SELECT Invoice_ID, Total_Billed, Payment_Status, Payment_Method
FROM Invoices
WHERE Payment_Status = :target_status; 
-- 傳入 0: 待結帳, 1: 已結帳


-- [Update] 結帳付款操作

UPDATE Invoices 
SET Payment_Status = 1, 
    Payment_Method = :payment_method 
WHERE Invoice_ID = :invoice_id AND Payment_Status = 0;


-- [Delete] 帳單作廢

UPDATE Invoices 
SET Payment_Status = 2 
WHERE Invoice_ID = :invoice_id;




























