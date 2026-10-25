-- Run in the attachments database as the operator / SQL Entra administrator.
SELECT ImportId, ContentHash, ImportedAt, [RowCount] FROM dbo.Imports ORDER BY ImportedAt DESC;

-- Each worksheet data row is a separate SQL row. Headers become JSON keys.
SELECT ImportId, RowNumber,
       JSON_VALUE(RowData, '$.record_id') AS RecordId,
       JSON_VALUE(RowData, '$.category') AS Category,
       TRY_CONVERT(float, JSON_VALUE(RowData, '$.value')) AS Value
FROM dbo.WorkbookRows
ORDER BY ImportId, RowNumber;

-- The example workbook gives count=3, sum=60, mean=20 and sample stddev=10.
SELECT ImportId, COUNT(*) AS [RowCount],
       SUM(TRY_CONVERT(float, JSON_VALUE(RowData, '$.value'))) AS Total,
       AVG(TRY_CONVERT(float, JSON_VALUE(RowData, '$.value'))) AS Mean,
       STDEV(TRY_CONVERT(float, JSON_VALUE(RowData, '$.value'))) AS SampleStandardDeviation
FROM dbo.WorkbookRows
GROUP BY ImportId;
