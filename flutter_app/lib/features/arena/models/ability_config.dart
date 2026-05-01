class AbilityConfig {
  final String id;
  final String archetype;
  final String abilityType; // 'passive' | 'core' | 'signature' | 'ultimate'
  final String displayName;
  final String description;
  final String? icon;
  final int cooldownSeconds;
  final int durationSeconds;
  final int tokenCost;
  final String target; // 'self' | 'opponent' | 'both'
  final String modifier;
  final double modifierValue;
  final String? triggerWindow;
  final Map<String, dynamic> metadata;

  const AbilityConfig({
    required this.id,
    required this.archetype,
    required this.abilityType,
    required this.displayName,
    required this.description,
    this.icon,
    required this.cooldownSeconds,
    required this.durationSeconds,
    required this.tokenCost,
    required this.target,
    required this.modifier,
    required this.modifierValue,
    this.triggerWindow,
    required this.metadata,
  });

  bool get isPassive => abilityType == 'passive';
  bool get isUltimate => abilityType == 'ultimate';

  factory AbilityConfig.fromJson(Map<String, dynamic> json) {
    return AbilityConfig(
      id:              json['id'] as String,
      archetype:       json['archetype'] as String,
      abilityType:     json['ability_type'] as String,
      displayName:     json['display_name'] as String,
      description:     json['description'] as String,
      icon:            json['icon'] as String?,
      cooldownSeconds: (json['cooldown_seconds'] as num).toInt(),
      durationSeconds: (json['duration_seconds'] as num).toInt(),
      tokenCost:       (json['token_cost'] as num).toInt(),
      target:          json['target'] as String,
      modifier:        json['modifier'] as String,
      modifierValue:   (json['modifier_value'] as num).toDouble(),
      triggerWindow:   json['trigger_window'] as String?,
      metadata:        (json['metadata'] as Map<String, dynamic>?) ?? {},
    );
  }
}
