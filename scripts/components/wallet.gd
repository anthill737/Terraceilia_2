extends Node
class_name Wallet

var money: float = 0.0


func can_afford(cost: float) -> bool:
	return money >= cost


func debit(cost: float) -> bool:
	if cost <= 0.0:
		return true
	if money < cost:
		return false
	money -= cost
	return true


func credit(amount: float) -> void:
	if amount > 0.0:
		money += amount
