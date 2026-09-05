import Foundation
import Testing
@testable import DPReader

private func schemaDecoder(_ major: Int, _ minor: Int = 0) -> JSONDecoder {
    let version = Version(major: major, minor: minor)
    let decoder = makeTestingJSONDecoder(.latestSupported)
    decoder.setDPReaderVersioning(PackVersioning(supportedVersions: .exactly(version), selectedVersion: version))
    return decoder
}

private func expectSchemaRejection<T: Decodable>(
    _ type: T.Type,
    json: String,
    format: Version,
    mentioning expectedText: String
) {
    do {
        _ = try schemaDecoder(format.major, format.minor).decode(type, from: Data(json.utf8))
        Issue.record("Expected pack format \(format) to reject \(T.self)")
    } catch {
        #expect(String(describing: error).contains(expectedText), "Unexpected schema error: \(error)")
    }
}

private let minimalEnchantmentJSON = """
{
  "description": "Test",
  "supported_items": "minecraft:stick",
  "weight": 1025,
  "max_level": 1,
  "min_cost": {"base": 1, "per_level_above_first": 0},
  "max_cost": {"base": 1, "per_level_above_first": 0},
  "anvil_cost": 0,
  "slots": ["mainhand"]
}
"""

@Test func testFormat42And44EnchantmentBoundaries() throws {
    expectSchemaRejection(
        Enchantment.self,
        json: minimalEnchantmentJSON,
        format: Version(major: 41, minor: 0),
        mentioning: "42.0+"
    )
    _ = try schemaDecoder(43).decode(Enchantment.self, from: Data(minimalEnchantmentJSON.utf8))
    expectSchemaRejection(
        Enchantment.self,
        json: minimalEnchantmentJSON,
        format: Version(major: 44, minor: 0),
        mentioning: "at most 1024"
    )
}

@Test func testFormat42LootEntityTargetRename() throws {
    let legacy = #"{"condition":"minecraft:entity_properties","entity":"killer"}"#
    let current = #"{"condition":"minecraft:entity_properties","entity":"attacker"}"#

    _ = try schemaDecoder(41).decode(LootConditionInitializer.self, from: Data(legacy.utf8))
    expectSchemaRejection(
        LootConditionInitializer.self,
        json: current,
        format: Version(major: 41, minor: 0),
        mentioning: "requires pack format 42.0"
    )
    expectSchemaRejection(
        LootConditionInitializer.self,
        json: legacy,
        format: Version(major: 42, minor: 0),
        mentioning: "was removed"
    )
    _ = try schemaDecoder(42).decode(LootConditionInitializer.self, from: Data(current.utf8))

    let legacyCopyName = #"{"function":"minecraft:copy_name","source":"killer"}"#
    let currentCopyName = #"{"function":"minecraft:copy_name","source":"attacking_entity"}"#
    _ = try schemaDecoder(41).decode(ItemModifierInitializer.self, from: Data(legacyCopyName.utf8))
    expectSchemaRejection(
        ItemModifierInitializer.self,
        json: legacyCopyName,
        format: Version(major: 42, minor: 0),
        mentioning: "not valid"
    )
    _ = try schemaDecoder(42).decode(ItemModifierInitializer.self, from: Data(currentCopyName.utf8))
}

@Test func testFormat44And46JigsawBoundaries() throws {
    let scalarPadding = """
    {
      "max_distance_from_center": 32,
      "size": 1,
      "start_height": {"absolute": 0},
      "start_pool": "test:start",
      "dimension_padding": 1
    }
    """
    expectSchemaRejection(
        JigsawStructureSettings.self,
        json: scalarPadding,
        format: Version(major: 42, minor: 0),
        mentioning: "43.0+"
    )
    _ = try schemaDecoder(43).decode(JigsawStructureSettings.self, from: Data(scalarPadding.utf8))

    let objectPadding = """
    {
      "max_distance_from_center": 32,
      "size": 1,
      "start_height": {"absolute": 0},
      "start_pool": "test:start",
      "dimension_padding": {"bottom": 1, "top": 2}
    }
    """
    expectSchemaRejection(
        JigsawStructureSettings.self,
        json: objectPadding,
        format: Version(major: 43, minor: 0),
        mentioning: "44.0+"
    )
    _ = try schemaDecoder(44).decode(JigsawStructureSettings.self, from: Data(objectPadding.utf8))

    let liquidSettings = """
    {
      "max_distance_from_center": 32,
      "size": 1,
      "start_height": {"absolute": 0},
      "start_pool": "test:start",
      "liquid_settings": "ignore_waterlogging"
    }
    """
    expectSchemaRejection(
        JigsawStructureSettings.self,
        json: liquidSettings,
        format: Version(major: 45, minor: 0),
        mentioning: "46.0+"
    )
    _ = try schemaDecoder(46).decode(JigsawStructureSettings.self, from: Data(liquidSettings.utf8))
}

@Test func testFormat43SNBTAndEnchantmentEventBoundaries() throws {
    let snbt = #"{"function":"minecraft:set_custom_data","tag":"{answer:42}"}"#
    expectSchemaRejection(
        ItemModifierInitializer.self,
        json: snbt,
        format: Version(major: 42, minor: 0),
        mentioning: "43.0+"
    )
    _ = try schemaDecoder(43).decode(ItemModifierInitializer.self, from: Data(snbt.utf8))

    let componentSNBT = #"{"function":"minecraft:set_components","components":{"minecraft:custom_data":"{answer:42}"}}"#
    expectSchemaRejection(
        ItemModifierInitializer.self,
        json: componentSNBT,
        format: Version(major: 42, minor: 0),
        mentioning: "43.0"
    )
    _ = try schemaDecoder(43).decode(ItemModifierInitializer.self, from: Data(componentSNBT.utf8))

    let enchantment = """
    {
      "description": "Test",
      "supported_items": "minecraft:stick",
      "weight": 1,
      "max_level": 1,
      "min_cost": {"base": 1, "per_level_above_first": 0},
      "max_cost": {"base": 1, "per_level_above_first": 0},
      "anvil_cost": 0,
      "slots": ["mainhand"],
      "effects": {
        "minecraft:tick": [{
          "effect": {
            "type": "minecraft:replace_block",
            "block_state": {"Name": "minecraft:stone"},
            "offset": [0, 0, 0],
            "predicate": {},
            "trigger_game_event": "minecraft:block_place"
          }
        }]
      }
    }
    """
    expectSchemaRejection(
        Enchantment.self,
        json: enchantment,
        format: Version(major: 42, minor: 0),
        mentioning: "trigger_game_event requires pack format 43.0"
    )
    _ = try schemaDecoder(43).decode(Enchantment.self, from: Data(enchantment.utf8))
}

@Test func testFormat46LevelBasedValueBoundaryAndShape() throws {
    let earlyLookup = #"{"condition":"minecraft:random_chance_with_enchanted_bonus","chance":{"type":"minecraft:lookup","values":[0.1],"fallback":0.2},"enchantment":"minecraft:looting"}"#
    expectSchemaRejection(
        LootConditionInitializer.self,
        json: earlyLookup,
        format: Version(major: 45, minor: 0),
        mentioning: "46.0"
    )

    let malformedLinear = #"{"condition":"minecraft:random_chance_with_enchanted_bonus","unenchanted_chance":0.1,"enchanted_chance":{"type":"minecraft:linear","per_level_above_first":0.1},"enchantment":"minecraft:looting"}"#
    expectSchemaRejection(
        LootConditionInitializer.self,
        json: malformedLinear,
        format: Version(major: 46, minor: 0),
        mentioning: "requires numeric base"
    )
}

@Test func testFormat59CustomModelDataBoundary() throws {
    let legacy = #"{"function":"minecraft:set_custom_model_data","value":1}"#
    let modern = #"{"function":"minecraft:set_custom_model_data","floats":{"mode":"replace_all","values":[1.0]}}"#
    let modernHexColor = ##"{"function":"minecraft:set_custom_model_data","colors":{"values":["#102030"]}}"##
    let modernVectorColor = #"{"function":"minecraft:set_custom_model_data","colors":{"values":[[0.1,0.2,0.3]]}}"#

    _ = try schemaDecoder(58).decode(ItemModifierInitializer.self, from: Data(legacy.utf8))
    expectSchemaRejection(
        ItemModifierInitializer.self,
        json: modern,
        format: Version(major: 58, minor: 0),
        mentioning: "59.0"
    )
    expectSchemaRejection(
        ItemModifierInitializer.self,
        json: legacy,
        format: Version(major: 59, minor: 0),
        mentioning: "removed"
    )
    _ = try schemaDecoder(59).decode(ItemModifierInitializer.self, from: Data(modern.utf8))
    expectSchemaRejection(
        ItemModifierInitializer.self,
        json: modernHexColor,
        format: Version(major: 91, minor: 0),
        mentioning: "wrong type"
    )
    _ = try schemaDecoder(92).decode(ItemModifierInitializer.self, from: Data(modernHexColor.utf8))
    _ = try schemaDecoder(92).decode(ItemModifierInitializer.self, from: Data(modernVectorColor.utf8))
}

@Test func testFormat68And92BiomeColorBoundaries() throws {
    func biome(_ effects: String) -> String {
        """
        {"has_precipitation":true,"temperature":0.5,"downfall":0.5,"effects":\(effects)}
        """
    }

    expectSchemaRejection(
        Biome.self,
        json: biome(#"{"dry_foliage_color":1}"#),
        format: Version(major: 67, minor: 0),
        mentioning: "68.0"
    )
    _ = try schemaDecoder(68).decode(Biome.self, from: Data(biome(#"{"dry_foliage_color":1}"#).utf8))
    expectSchemaRejection(
        Biome.self,
        json: biome(##"{"water_color":"#102030"}"##),
        format: Version(major: 91, minor: 0),
        mentioning: "integer before pack format 92.0"
    )
    _ = try schemaDecoder(92).decode(Biome.self, from: Data(biome(##"{"water_color":"#102030"}"##).utf8))
}

@Test func testFormat82WorldgenAndLootBoundaries() throws {
    let modernTarget = #"{"condition":"minecraft:entity_properties","entity":"target_entity"}"#
    expectSchemaRejection(
        LootConditionInitializer.self,
        json: modernTarget,
        format: Version(major: 81, minor: 0),
        mentioning: "82.0"
    )
    _ = try schemaDecoder(82).decode(LootConditionInitializer.self, from: Data(modernTarget.utf8))

    let interactionTable = #"{"type":"minecraft:entity_interact","pools":[]}"#
    expectSchemaRejection(
        LootTable.self,
        json: interactionTable,
        format: Version(major: 81, minor: 0),
        mentioning: "82.0+"
    )
    _ = try schemaDecoder(82).decode(LootTable.self, from: Data(interactionTable.utf8))

    let copyTargetData = #"{"function":"minecraft:copy_custom_data","source":"interacting_entity","ops":[]}"#
    expectSchemaRejection(
        ItemModifierInitializer.self,
        json: copyTargetData,
        format: Version(major: 81, minor: 0),
        mentioning: "82.0"
    )
    _ = try schemaDecoder(82).decode(ItemModifierInitializer.self, from: Data(copyTargetData.utf8))

    let invert = #"{"type":"minecraft:invert","argument":2.0}"#
    expectSchemaRejection(
        DensityFunctionInitializer.self,
        json: invert,
        format: Version(major: 81, minor: 0),
        mentioning: "82.0+"
    )
    _ = try schemaDecoder(82).decode(DensityFunctionInitializer.self, from: Data(invert.utf8))

    let findTopSurface = #"{"type":"minecraft:find_top_surface","density":1.0,"upper_bound":64.0,"lower_bound":-64,"cell_height":0}"#
    expectSchemaRejection(
        DensityFunctionInitializer.self,
        json: findTopSurface,
        format: Version(major: 82, minor: 0),
        mentioning: "positive integer"
    )

    let objectDistance = """
    {
      "max_distance_from_center": {"horizontal": 32},
      "size": 1,
      "start_height": {"absolute": 0},
      "start_pool": "test:start"
    }
    """
    expectSchemaRejection(
        JigsawStructureSettings.self,
        json: objectDistance,
        format: Version(major: 81, minor: 0),
        mentioning: "82.0+"
    )
    let jigsaw = try schemaDecoder(82).decode(JigsawStructureSettings.self, from: Data(objectDistance.utf8))
    #expect(jigsaw.maxDistanceFromCenter == 32)
    #expect(jigsaw.maxVerticalDistanceFromCenter == 4_096)

    let modernNoiseRouter = """
    {
      "preliminary_surface_level": 1.0,
      "final_density": 1.0,
      "barrier": 0.0,
      "fluid_level_floodedness": 0.0,
      "fluid_level_spread": 0.0,
      "lava": 0.0,
      "vein_toggle": 0.0,
      "vein_ridged": 0.0,
      "vein_gap": 0.0,
      "temperature": 0.0,
      "vegetation": 0.0,
      "continents": 0.0,
      "erosion": 0.0,
      "depth": 0.0,
      "ridges": 0.0
    }
    """
    let legacyNoiseRouter = modernNoiseRouter.replacingOccurrences(
        of: "preliminary_surface_level",
        with: "initial_density_without_jaggedness"
    )
    _ = try schemaDecoder(81).decode(NoiseRouter.self, from: Data(legacyNoiseRouter.utf8))
    _ = try schemaDecoder(82).decode(NoiseRouter.self, from: Data(modernNoiseRouter.utf8))
    expectSchemaRejection(
        NoiseRouter.self,
        json: legacyNoiseRouter,
        format: Version(major: 82, minor: 0),
        mentioning: "was removed"
    )
    expectSchemaRejection(
        NoiseRouter.self,
        json: modernNoiseRouter,
        format: Version(major: 81, minor: 0),
        mentioning: "requires pack format 82.0"
    )
}

@Test func testFormat91And92LootBoundaries() throws {
    let oldFiltered = #"{"function":"minecraft:filtered","item_filter":{},"modifier":{"function":"minecraft:discard"}}"#
    let newFiltered = #"{"function":"minecraft:filtered","item_filter":{},"on_fail":{"function":"minecraft:discard"}}"#
    expectSchemaRejection(
        ItemModifierInitializer.self,
        json: newFiltered,
        format: Version(major: 90, minor: 0),
        mentioning: "91.0"
    )
    expectSchemaRejection(
        ItemModifierInitializer.self,
        json: oldFiltered,
        format: Version(major: 91, minor: 0),
        mentioning: "removed"
    )
    _ = try schemaDecoder(91).decode(ItemModifierInitializer.self, from: Data(newFiltered.utf8))

    let slots = #"{"type":"minecraft:slots","slot_source":{"type":"minecraft:empty"}}"#
    expectSchemaRejection(
        LootEntryInitializer.self,
        json: slots,
        format: Version(major: 91, minor: 0),
        mentioning: "92.0+"
    )
    _ = try schemaDecoder(92).decode(LootEntryInitializer.self, from: Data(slots.utf8))

    let dynamicContents = #"{"type":"minecraft:dynamic","name":"contents"}"#
    expectSchemaRejection(
        LootEntryInitializer.self,
        json: dynamicContents,
        format: Version(major: 92, minor: 0),
        mentioning: "unavailable"
    )
    _ = try schemaDecoder(93, 1).decode(LootEntryInitializer.self, from: Data(dynamicContents.utf8))
}

@Test func testFormat97And101Point2Boundaries() throws {
    let clockedCondition = #"{"condition":"minecraft:time_check","clock":"minecraft:overworld","value":0}"#
    expectSchemaRejection(
        LootConditionInitializer.self,
        json: clockedCondition,
        format: Version(major: 96, minor: 0),
        mentioning: "97.0"
    )
    _ = try schemaDecoder(97).decode(LootConditionInitializer.self, from: Data(clockedCondition.utf8))

    let directProtectedBlock = #"{"processors":[{"processor_type":"minecraft:protected_blocks","value":"minecraft:bedrock"}]}"#
    expectSchemaRejection(
        StructureProcessorList.self,
        json: directProtectedBlock,
        format: Version(major: 101, minor: 1),
        mentioning: "hash-prefixed"
    )
    _ = try schemaDecoder(101, 2).decode(StructureProcessorList.self, from: Data(directProtectedBlock.utf8))
}

@Test func testFormat104And105WorldgenBoundaries() throws {
    let interval = """
    {"type":"minecraft:interval_select","input":0.5,"thresholds":[0.0],"functions":[1.0,2.0]}
    """
    expectSchemaRejection(
        DensityFunctionInitializer.self,
        json: interval,
        format: Version(major: 103, minor: 0),
        mentioning: "104.0+"
    )
    _ = try schemaDecoder(104).decode(DensityFunctionInitializer.self, from: Data(interval.utf8))

    let weird = """
    {"type":"minecraft:weird_scaled_sampler","rarity_value_mapper":"type_1","input":1.0,"noise":"minecraft:test"}
    """
    _ = try schemaDecoder(103).decode(DensityFunctionInitializer.self, from: Data(weird.utf8))
    expectSchemaRejection(
        DensityFunctionInitializer.self,
        json: weird,
        format: Version(major: 104, minor: 0),
        mentioning: "103"
    )

    let threshold3D = #"{"type":"minecraft:noise_threshold","noise":"minecraft:test","min_threshold":-1,"max_threshold":1,"is_3d":true}"#
    expectSchemaRejection(
        SurfaceRuleConditionInitializer.self,
        json: threshold3D,
        format: Version(major: 104, minor: 0),
        mentioning: "105.0+"
    )
    _ = try schemaDecoder(105).decode(SurfaceRuleConditionInitializer.self, from: Data(threshold3D.utf8))
}
