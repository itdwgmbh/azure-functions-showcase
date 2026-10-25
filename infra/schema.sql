IF OBJECT_ID(N'dbo.Imports', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Imports (
        ImportId char(64) NOT NULL PRIMARY KEY,
        MessageId nvarchar(2048) NOT NULL,
        AttachmentId nvarchar(2048) NOT NULL,
        ContentHash char(64) NOT NULL,
        [RowCount] int NOT NULL,
        ImportedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
END;

IF OBJECT_ID(N'dbo.WorkbookRows', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.WorkbookRows (
        ImportId char(64) NOT NULL REFERENCES dbo.Imports(ImportId) ON DELETE CASCADE,
        RowNumber int NOT NULL,
        RowData nvarchar(max) NOT NULL CHECK (ISJSON(RowData) = 1),
        CONSTRAINT PK_WorkbookRows PRIMARY KEY (ImportId, RowNumber)
    );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Imports') AND name = N'IX_Imports_ContentHash')
    CREATE INDEX IX_Imports_ContentHash ON dbo.Imports(ContentHash);
GO

CREATE OR ALTER PROCEDURE dbo.ImportWorkbook
    @ContentHash char(64),
    @MessageId nvarchar(2048),
    @AttachmentId nvarchar(2048),
    @Rows nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @LockResult int;
        DECLARE @LockName nvarchar(255) = N'workbook-import:' + @ContentHash;
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockName, @LockMode = 'Exclusive',
            @LockOwner = 'Transaction', @LockTimeout = 10000;
        IF @LockResult < 0
            THROW 51000, 'Could not acquire the import lock.', 1;

        DECLARE @ExistingId char(64), @ExistingCount int;
        SELECT TOP (1) @ExistingId = ImportId, @ExistingCount = [RowCount]
        FROM dbo.Imports WHERE ContentHash = @ContentHash
        ORDER BY ImportedAt;

        IF @ExistingId IS NOT NULL
        BEGIN
            COMMIT TRANSACTION;
            SELECT @ExistingId AS ImportId, @ExistingCount AS [RowCount], 'already_processed' AS Status;
            RETURN;
        END;

        DECLARE @RowCount int = (SELECT COUNT(*) FROM OPENJSON(@Rows));
        IF @RowCount = 0
            THROW 51002, 'No workbook rows supplied.', 1;

        INSERT INTO dbo.Imports (ImportId, MessageId, AttachmentId, ContentHash, [RowCount])
        VALUES (@ContentHash, @MessageId, @AttachmentId, @ContentHash, @RowCount);

        INSERT INTO dbo.WorkbookRows (ImportId, RowNumber, RowData)
        SELECT @ContentHash, RowNumber, RowData
        FROM OPENJSON(@Rows) WITH (
            RowNumber int '$.row_number',
            RowData nvarchar(max) '$.data' AS JSON
        );

        COMMIT TRANSACTION;
        SELECT @ContentHash AS ImportId, @RowCount AS [RowCount], 'imported' AS Status;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
