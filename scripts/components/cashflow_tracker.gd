extends Node
class_name CashflowTracker

## Tracks per-agent income/expense each day and maintains a rolling 7-day
## net-cashflow history.  Pure diagnostics -- no AI or economy effect.

var today_income: float = 0.0
var today_expense: float = 0.0
var history_7d: Array[float] = []


func record_income(amount: float) -> void:
	today_income += amount


func record_expense(amount: float) -> void:
	today_expense += amount


func roll_daily() -> void:
	var net: float = today_income - today_expense
	history_7d.append(net)
	if history_7d.size() > 7:
		history_7d.pop_front()
	today_income = 0.0
	today_expense = 0.0


func rolling_7d_sum() -> float:
	var s: float = 0.0
	for v: float in history_7d:
		s += v
	return s


func rolling_7d_avg() -> float:
	if history_7d.is_empty():
		return 0.0
	return rolling_7d_sum() / float(history_7d.size())


func day_count() -> int:
	return history_7d.size()
