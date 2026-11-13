class_name Clothing
extends RefCounted
## Clothes (docs/CLOTHES.md). Everyone wears clothes, and they wear out. Anthony's rule: people
## buy what they wear unless they make it themselves, and which they do is their own choice.
##
## - A set of clothes lasts LIFE_DAYS of wear, then it is rags. Someone in rags feels the cold:
##   in a hard frost their hearth burns twice the wood (LaborMarket._update_firewood); someone
##   decently dressed gets by on one log.
## - No two sets last quite the same: a set lasts LIFE_DAYS, give or take LIFE_SPREAD.
## - Buying: what a new set is worth to someone grows the more worn their clothes are, and
##   what its price feels like to them depends on their purse (a coin is worth more the thinner
##   the purse). They buy when the set is worth its price to them, never before their clothes
##   are half worn, and never with the coins for KEEP_DAYS of food, firewood and rent. So
##   people with coins to spare spend some of them, and people with little patch and wait.
## - Making your own: someone with no work, in rags, for whom buying is not worth it, spins
##   and sews a set of their own. It takes SEW_DAYS of their time.
## - A set already in hand (a tailor's own, say) goes on when the old one is worn through.
##
## The clothes are made by tailors (TailorJob) and sold at the market like any good; the buyer
## pays the tailor whose stall they pick (docs/BUY_FROM_MAKERS.md).

const LIFE_DAYS: float = 30.0      # days a set of clothes lasts before it is rags
const WORTH_DAYS: float = 3.0      # a new set, to someone in rags with a comfortable purse, is worth this many days of keep
const MIN_WEAR: float = 0.5        # nobody replaces clothes less than half worn
const KEEP_DAYS: float = 10.0      # days of food, firewood and rent nobody spends on clothes (Housing.CUSHION_DAYS)
const SEW_DAYS: int = 5            # days it takes someone to spin and sew a set of their own
const LIFE_SPREAD: float = 0.3     # a set lasts this share more or less than LIFE_DAYS

var village = null
var stats := {"bought": 0, "sewn": 0, "spent": 0.0}


static func on() -> bool:
	return Tuning.on("clothes", true)


static func life_days() -> float:
	return maxf(1.0, Tuning.f("clothes_days", LIFE_DAYS))


## How worn `a`'s clothes are: 0 new, 1 rags.
static func wear_of(a) -> float:
	return clampf(float(a.get_meta("clothes_wear", 0.0)), 0.0, 1.0) if a != null and is_instance_valid(a) else 0.0


## True unless `a` is in rags.
static func dressed(a) -> bool:
	return not on() or a == null or not is_instance_valid(a) or wear_of(a) < 1.0


## Everyone who wears clothes: the people with no shop and every shop owner. (Merchants are
## switched off; they would be the same.)
func people() -> Array:
	var out: Array = []
	if village == null:
		return out
	for grp in [village.households] + village.owner_groups():
		for a in grp:
			if a != null and is_instance_valid(a) and not a.is_queued_for_deletion() and a.get("inv") != null:
				out.append(a)
	return out


## A day's keep: a loaf, a log and the rent (LaborMarket.wage_floor).
func keep_day() -> float:
	return float(village.labor_market.wage_floor()) if village != null and village.labor_market != null else 5.0


## What a coin is worth to `a`: one with Housing.CUSHION_DAYS of keep in the purse feels a coin
## as a coin, one with half that as two, one with twice that as half.
func coin_weight(a) -> float:
	return Housing.CUSHION_DAYS * keep_day() / maxf(0.01, a.get_cash())


## How worn `a`'s clothes must be before a new set at `price` is worth it to them. Over 1:
## never (they would sooner wear rags).
func buy_at_wear(a, price: float) -> float:
	return maxf(MIN_WEAR, price * coin_weight(a) / maxf(0.01, WORTH_DAYS * keep_day()))


func can_afford(a, price: float) -> bool:
	return a.get_cash() - KEEP_DAYS * keep_day() >= price


func wants_clothes(a, price: float) -> bool:
	var w: float = buy_at_wear(a, price)
	return w <= 1.0 and wear_of(a) >= w and can_afford(a, price)


## What the town would spend on clothes in a day at `price`, and how many sets it would buy:
## each person who would buy at all replaces a set every buy_at_wear x LIFE_DAYS days.
func spending_per_day(price: float) -> Dictionary:
	var sets: float = 0.0
	for a in people():
		if not can_afford(a, price):
			continue
		var w: float = buy_at_wear(a, price)
		if w <= 1.0:
			sets += 1.0 / (w * life_days())
	return {"coins": sets * price, "sets": sets}


## A set to start with, partly worn, so a town's clothes do not all wear out on the same day.
static func _start_wear(a) -> float:
	return float(absi(hash(str(a.get_instance_id()))) % 1000) / 1000.0 * 0.6


## A new set goes on. No two sets last quite the same (LIFE_SPREAD either way), so a town does
## not all need new clothes on the same day.
func _put_on_new(a) -> void:
	a.set_meta("clothes_wear", 0.0)
	a.set_meta("clothes_life", life_days() * (1.0 + LIFE_SPREAD * (2.0 * randf() - 1.0)))
	a.set_meta("sewing_days", 0)


## Once a day.
func on_day(_day: int) -> void:
	if not on() or village == null:
		return
	var m = village.market
	var has_market: bool = m != null and m.has_good("clothes")
	for a in people():
		if not a.has_meta("clothes_wear"):
			a.set_meta("clothes_wear", _start_wear(a))
		a.set_meta("clothes_wear", minf(1.0, float(a.get_meta("clothes_wear")) + 1.0 / float(a.get_meta("clothes_life", life_days()))))
		# A set already in hand goes on once the old one is worn through.
		if wear_of(a) >= 1.0 and a.inv.get_qty("clothes") > 0:
			a.inv.remove("clothes", 1)
			_put_on_new(a)
			continue
		if has_market:
			var price: float = m.good_price("clothes")
			# Asked for even when the shelf is bare: that is how the price learns somebody wants
			# clothes. (With no asking, a bare shelf kept its price and no tailor ever made more.)
			if wants_clothes(a, price):
				var before: float = a.get_cash()
				if m.buy_good(a, "clothes", 1) == 1:
					a.inv.remove("clothes", 1)
					_put_on_new(a)
					stats.bought += 1
					stats.spent += before - a.get_cash()
					if a.has_method("log_event"):
						a.log_event("Bought new clothes for $%.2f." % (before - a.get_cash()))
					continue
		# Making their own: someone with no work, in rags, who will not pay today's price.
		if wear_of(a) >= 1.0 and village.households.has(a) and village.labor_market != null and village.labor_market.is_idle(a):
			var d: int = int(a.get_meta("sewing_days", 0)) + 1
			if d >= SEW_DAYS:
				_put_on_new(a)
				stats.sewn += 1
				if a.has_method("log_event"):
					a.log_event("Finished spinning and sewing a set of clothes of their own.")
			else:
				a.set_meta("sewing_days", d)
