"""Create attachment.xlsx for the email demo."""

from pathlib import Path

from openpyxl import Workbook
from openpyxl.styles import Font

workbook = Workbook()
sheet = workbook.active
sheet.title = "Measurements"
sheet.append(["record_id", "category", "value"])
sheet.append([1, "A", 10])
sheet.append([2, "A", 20])
sheet.append([3, "B", 30])
for cell in sheet[1]:
    cell.font = Font(bold=True)
for column in ("A", "B", "C"):
    sheet.column_dimensions[column].width = 18
sheet.freeze_panes = "A2"
destination = Path(__file__).with_name("attachment.xlsx")
workbook.save(destination)
print(destination)
