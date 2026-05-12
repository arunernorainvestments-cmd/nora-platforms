class AbilityData {
  final int slot;
  final String name;
  final int apCost;
  final bool requiresMomentum;

  const AbilityData({
    required this.slot,
    required this.name,
    required this.apCost,
    this.requiresMomentum = false,
  });
}

class BenchCharacter {
  final String archetype;
  final String displayName;
  final int currentHp;
  final int maxHp;
  final bool isKO;

  const BenchCharacter({
    required this.archetype,
    required this.displayName,
    required this.currentHp,
    required this.maxHp,
    this.isKO = false,
  });
}
