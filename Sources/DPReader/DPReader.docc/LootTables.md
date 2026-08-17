# Loot Tables

Loot tables are used when Minecraft needs to randomly generate items.

Minecraft uses loot tables to randomly generate items in a wide variety of situations, from chest loot to fishing to mob drops. Loot tables intended for different purposes will often use different functions and conditions. Currently, DPReader only uses loot tables internally for chest loot, but it can load any kind of loot table.

## Topics

### Basic Structures

These are the basic structures used by DPReader to represent loot tables.

- ``LootTable``
- ``LootTableEntry``
- ``LootPool``
- ``LootContext``

### Loot Entries

Loot entries are the basic building blocks of loot tables. They can be evaluated to yield items.

- ``LootEntry``
- ``LootEntryInitializer``
- ``AlternativesEntry``
- ``CompositeLootEntry``
- ``DynamicEntry``
- ``EmptyEntry``
- ``GroupEntry``
- ``ItemEntry``
- ``LootTableEntry``
- ``SequenceEntry``
- ``SingletonLootEntry``
- ``TagEntry``

### Loot Conditions

Loot conditions are used to decide whether pools or entries should be evaluated.

- ``LootCondition``
- ``LootConditionInitializer``
- ``AllOfLootCondition``
- ``AlternativeLootCondition``
- ``AnyOfLootCondition``
- ``BlockStatePropertyLootCondition``
- ``DamageSourcePropertiesLootCondition``
- ``EnchantmentActiveCheckLootCondition``
- ``EntityPropertiesLootCondition``
- ``EntityScoresLootCondition``
- ``InvertedLootCondition``
- ``KilledByPlayerLootCondition``
- ``LocationCheckLootCondition``
- ``MatchToolLootCondition``
- ``RandomChanceLootCondition``
- ``RandomChanceWithEnchantedBonusLootCondition``
- ``ReferenceLootCondition``
- ``SurvivesExplosionLootCondition``
- ``TableBonusLootCondition``
- ``TimeCheckLootCondition``
- ``ValueCheckLootCondition``
- ``WeatherCheckLootCondition``

### Item Modifiers

Item modifiers can be used from loot tables and commands to modify items.

- ``ItemModifier``
- ``ItemModifierInitializer``
- ``ApplyBonusItemModifier``
- ``ApplyBonusFormula``
- ``ConditionalItemModifier``
- ``CopyComponentsItemModifier``
- ``CopyCustomDataItemModifier``
- ``CopyCustomDataOperation``
- ``CopyNameItemModifier``
- ``CopyStateItemModifier``
- ``DiscardItemModifier``
- ``EnchantRandomlyItemModifier``
- ``EnchantWithLevelsItemModifier``
- ``EnchantedCountIncreaseItemModifier``
- ``ExplorationMapItemModifier``
- ``ExplosionDecayItemModifier``
- ``FillPlayerHeadItemModifier``
- ``FilteredItemModifier``
- ``FurnaceSmeltItemModifier``
- ``LimitCountItemModifier``
- ``ModifyComponentsItemModifier``
- ``ReferenceItemModifier``
- ``SequenceItemModifier``
- ``SetAttributesItemModifier``
- ``SetAttributeModifier``
- ``SetBannerPatternItemModifier``
- ``SetBookCoverItemModifier``
- ``SetComponentsItemModifier``
- ``SetContentsItemModifier``
- ``SetCountItemModifier``
- ``SetCustomDataItemModifier``
- ``SetCustomModelDataItemModifier``
- ``SetDamageItemModifier``
- ``SetEnchantmentsItemModifier``
- ``SetFireworkExplosionItemModifier``
- ``SetFireworksItemModifier``
- ``SetInstrumentItemModifier``
- ``SetItemItemModifier``
- ``SetLootTableItemModifier``
- ``SetLoreItemModifier``
- ``SetNameItemModifier``
- ``SetOminousBottleAmplifierItemModifier``
- ``SetPotionItemModifier``
- ``SetRandomDyesItemModifier``
- ``SetRandomPotionItemModifier``
- ``SetStewEffectItemModifier``
- ``StewEffect``
- ``SetWritableBookPagesItemModifier``
- ``SetWrittenBookPagesItemModifier``
- ``ToggleTooltipsItemModifier``

### Loot Number Providers

Loot number providers are used to generate numbers in loot tables. These are not the only ones in the game.

- ``LootNumberProvider``
- ``LootNumberProviderInitializer``
- ``BinomialLootNumberProvider``
- ``ConstantLootNumberProvider``
- ``UniformLootNumberProvider``

### Items & Enchantments

- ``Enchantment``
- ``EnchantmentCost``
- ``ItemStack``

### Helpers

- ``LootEnchantmentResources``
- ``LootTableResolver``
- ``LootEvaluationError``
