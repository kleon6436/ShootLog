import CoreGraphics
import Foundation
import Vision

struct VisionLabelClassification: Equatable, Sendable {
    let categories: [AISubjectCategory]
    let rawIdentifiers: [String]
}

/// Visionの英語identifierを、アプリで扱う粗粒度カテゴリへ変換するサービス。
enum VisionLabelClassifier {
    static let maximumRawIdentifierCount = 10

    /// 画像を分類する。Visionの実行失敗・結果欠落時は `nil` を返す。
    /// 呼び出し側は `nil` を「分類済み・カテゴリなし」として永続化せず、次回読み込み時に再試行させる。
    static func classify(
        _ image: CGImage,
        maxResults: Int = Self.maximumRawIdentifierCount
    ) -> VisionLabelClassification? {
        // 呼び出し側が結果件数0を明示した場合は失敗ではないため、空の分類結果を返す。
        guard maxResults > 0 else {
            return VisionLabelClassification(categories: [], rawIdentifiers: [])
        }

        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision1

        do {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let results = request.results else {
            return nil
        }

        let rankedResults = results.sorted { $0.confidence > $1.confidence }
        let rawIdentifiers = rankedResults
            .prefix(maxResults)
            .map(\.identifier)
        let topResults = rankedResults
            .filter { $0.hasMinimumPrecision(0.55, forRecall: 0.65) }
            .prefix(maxResults)
        var categories: [AISubjectCategory] = []
        for result in topResults {
            let category = Self.category(for: result.identifier)
            guard !categories.contains(category) else { continue }
            categories.append(category)
        }

        return VisionLabelClassification(
            categories: categories,
            rawIdentifiers: rawIdentifiers
        )
    }

    static func category(for identifier: String) -> AISubjectCategory {
        let normalizedIdentifier = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return labelCategories[normalizedIdentifier] ?? .unknown
    }

    private static let labelCategories: [String: AISubjectCategory] = {
        let groupedLabels: [(AISubjectCategory, [String])] = [
            (.person, [
                "acrobat", "adult", "apron", "archery", "athletics", "baby", "badminton", "ballet", "ballet_dancer", "ballgames", "baseball", "baseball_hat",
                "basketball", "bathrobe", "beanie", "beekeeping", "bellydance", "bib", "bowling", "bowtie", "boxing", "breakdancing", "bride", "bridesmaid",
                "bullfighting", "bungee", "celebration", "ceremony", "cheerleading", "child", "cloak", "clothing", "clown", "concert", "conference", "costume",
                "cowboy_hat", "cricket_sport", "crowd", "cycling", "dancing", "deejay", "diving", "dragon_parade", "dressage", "earmuffs", "entertainer", "equestrian",
                "eyeglasses", "fedora", "fencing_sport", "fishing", "football", "golf", "gown", "graduation", "groom", "gymnastics", "hardhat", "hat",
                "headgear", "helmet", "henna", "hiking", "hockey", "hoodie", "hula", "hunting", "ice_skating", "jacket", "jeans", "jockey_horse",
                "juggling", "kickboxing", "kilt", "kimono", "kiteboarding", "lab_coat", "leotard", "loafer", "martial_arts", "military_uniform", "mitten", "moccasin",
                "motocross", "music", "necktie", "orchestra", "paintball", "parachute", "parade", "parasailing", "people", "performance", "ping_pong", "polo",
                "poncho", "putt", "rafting", "recreation", "rock_climbing", "rodeo", "rollerskating", "rugby", "safety_vest", "samba", "santa_claus", "sari",
                "scarf", "scuba", "singer", "skateboarding", "skating", "skiing", "skydiving", "sledding", "snorkeling", "snowboarding", "soccer", "softball",
                "sombrero", "sport", "squash_sport", "stroller", "suit", "sumo", "sunbathing", "sunglasses", "sunhat", "surfing", "swimming", "swimsuit",
                "tattoo", "teen", "tennis", "tuxedo", "volleyball", "wakeboarding", "waterpolo", "watersport", "wedding", "wedding_dress", "wetsuit", "windsurfing",
                "winter_sport", "workout", "wrestling", "yoga"
            ]),
            (.animal, [
                "adult_cat", "alligator_crocodile", "anchovy", "angelfish", "animal", "ant", "arachnid", "arthropods", "australian_shepherd", "barnacle", "barracuda", "basenji",
                "basset", "beagle", "bear", "bee", "beehive", "bernese_mountain", "bichon", "bird", "bison", "boar", "bobcat", "bulldog",
                "butterfly", "camel", "canine", "cat", "caterpillar", "centipede", "cephalopod", "cetacean", "chameleon", "cheetah", "chihuahua", "chinchilla",
                "clownfish", "cockatoo", "collie", "conch", "corgi", "cougar", "cow", "coyote_wolf", "crab", "dachshund", "dalmatian", "deer",
                "dinosaur", "doberman", "dog", "dolphin", "donkey", "dove", "dragonfly", "eagle", "elephant", "elk", "feline", "ferret",
                "fish", "flamingo", "fox", "frog", "gastropod", "gecko", "gerbil", "german_shepherd", "giraffe", "goat", "goldfish", "greyhound",
                "gull", "guppy", "hamster", "hedgehog", "heron", "hippopotamus", "horse", "hound", "hummingbird", "husky", "hyena", "iguana",
                "insect", "irish_wolfhound", "jack_russell_terrier", "jellyfish", "kangaroo", "kitten", "koala", "koi", "ladybug", "lemur", "leopard", "lion",
                "lionfish", "lizard", "llama", "lobster", "lynx", "mackerel", "malamute", "malinois", "mammal", "marsupial", "mastiff", "millipede",
                "mollusk", "monitor_lizard", "moose", "moth", "nest", "newfoundland", "ostrich", "otter", "owl", "oyster", "panda", "parakeet",
                "parrot", "peacock", "pelican", "penguin", "peregrine", "pig", "pigeon", "pitbull", "pomeranian", "poodle", "porcupine", "prairie_dog",
                "puffer_fish", "puffin", "pug", "python", "rabbit", "raccoon", "raptor", "rat", "rattlesnake", "raven", "reptile", "retriever",
                "rhinoceros", "ridgeback", "rodent", "rottweiler", "saint_bernard", "salmon", "sandpiper", "sardine", "scarab", "schnauzer", "scorpion", "seabass",
                "seahorse", "seal", "sealion", "setter", "shark", "sheep", "sheepdog", "shellfish", "skunk", "snail", "snake", "snake_other",
                "snapper", "spaniel", "sparrow", "spider", "spiderweb", "squirrel", "starfish", "stingray", "stork", "sunfish", "swan", "swordfish",
                "terrier", "tiger", "toad", "tortoise", "toucan", "trout", "tuna", "turtle", "ungulates", "urchin", "vizsla", "vulture",
                "walrus", "weimaraner", "whale", "woodpecker", "worm", "zebra", "zoo"
            ]),
            (.food, [
                "almond", "antipasti", "apple", "apricot", "artichoke", "arugula", "asparagus", "avocado", "bacon", "bagel", "baked_goods", "baklava",
                "banana", "bean", "beef", "beer", "beet", "bell_pepper", "berry", "birthday_cake", "biryani", "biscotti", "biscuit", "blackberry",
                "blueberry", "bread", "broccoli", "brownie", "bruschetta", "bubble_tea", "burrito", "butter", "cake", "cake_regular", "candy", "candy_cane",
                "candy_other", "cantaloupe", "caprese", "caramel", "carrot", "cashew", "casserole", "cauliflower", "celery", "cereal", "cheese", "cheesecake",
                "cherry", "chestnut", "chewing_gum", "chives", "chocolate", "chocolate_chip", "citrus_fruit", "clam", "cocktail", "coconut", "coffee", "coffee_bean",
                "coleslaw", "condiment", "cookie", "corn", "cranberry", "crepe", "croissant", "cucumber", "cupcake", "curry", "daikon", "dessert",
                "dill", "donut", "drink", "dumpling", "durian", "edamame", "egg", "eggplant", "falafel", "fig", "flan", "fondue",
                "food", "fried_chicken", "fried_egg", "fries", "frozen", "frozen_dessert", "fruit", "fruitcake", "garlic", "gingerbread", "grape", "grapefruit",
                "green_beans", "grilled_chicken", "guacamole", "guava", "gyoza", "habanero", "ham", "hamburger", "honey", "honeydew", "hotdog", "hummus",
                "ice_cream", "jalapeno", "jello", "jelly", "juice", "kebab", "kiwi", "kohlrabi", "leek", "lemon", "lemongrass", "lettuce",
                "lime", "liquor", "lollipop", "lychee", "macadamia", "mandarine", "mango", "mangosteen", "margarita", "marshmallow", "martini", "matzo",
                "meat", "meatball", "melon", "milkshake", "mojito", "muffin", "mushroom", "mussel", "mustard", "naan", "nachos", "nectarine",
                "nut", "oatmeal", "omelet", "onion", "oranges", "paella", "pancake", "papaya", "passionfruit", "pasta", "pastry", "pea",
                "peach", "peanut", "pear", "pecan", "pepper_veggie", "pepperoni", "persimmon", "pickle", "pie", "pierogi", "pineapple", "pistachio",
                "pita", "pizza", "plum", "pomegranate", "popcorn", "popsicle", "potato", "poultry", "pretzel", "pudding", "pumpkin", "quesadilla",
                "quinoa", "radish", "rambutan", "ramen", "raspberry", "red_wine", "rhubarb", "rice", "risotto", "roe", "salad", "salami",
                "samosa", "sandwich", "sangria", "satay", "sauerkraut", "sausage", "scallop", "scone", "scrambled_eggs", "seafood", "seasonings", "sesame",
                "shawarma", "shellfish_prepared", "smoothie", "soda", "souffle", "soup", "souvlaki", "spaghetti", "spareribs", "sparkling_wine", "spice", "spinach",
                "springroll", "starfruit", "steak", "stir_fry", "strawberry", "strudel", "sugar_cube", "sunflower_seeds", "sushi", "tabbouleh", "taco", "taffy",
                "tapas", "tapioca_pearls", "taro", "tea_drink", "tempura", "tequila", "teriyaki", "tiramisu", "tomato", "tortilla", "turmeric", "vegetable",
                "waffle", "wasabi", "watermelon", "wedding_cake", "wheat", "white_bread", "white_wine", "wine", "wine_bottle", "wonton", "yogurt", "yolk",
                "zucchini"
            ]),
            (.landscape, [
                "agriculture", "amusement_park", "aurora", "beach", "blizzard", "blue_sky", "camping", "canyon", "cave", "celestial_body", "celestial_body_other", "cliff",
                "cloudy", "coral_reef", "creek", "daytime", "desert", "dirt_road", "embers", "fairground", "farm", "fire", "fireworks", "flame",
                "forest", "garden", "geyser", "glacier", "golf_course", "haze", "hill", "ice", "iceberg", "island", "jungle", "lake",
                "land", "lava", "lightning", "mangrove", "moon", "mountain", "night_sky", "ocean", "orchard", "outdoor", "park", "path",
                "playground", "rainbow", "river", "road", "road_other", "rocks", "sand", "sand_dune", "sandcastle", "shore", "skatepark", "sky",
                "snow", "snowball", "snowman", "storm", "sun", "sunset_sunrise", "thunderstorm", "tornado", "trail", "underwater", "vineyard", "volcano",
                "water", "water_body", "waterfall", "waterways", "wetland"
            ]),
            (.building, [
                "airport", "alley", "apartment", "aquarium", "arch", "arena", "auditorium", "balcony", "bar", "barn", "belltower", "bleachers",
                "boathouse", "brick", "brick_oven", "bridge", "building", "carnival", "carousel", "casino", "castle", "cellar", "chimney", "circus",
                "cityscape", "clock_tower", "crosswalk", "dam", "deck", "dock", "dome", "domicile", "door", "driveway", "elevator", "escalator",
                "fence", "ferris_wheel", "fountain", "garage", "gargoyle", "gazebo", "grave", "greenhouse", "hangar", "harbour", "health_club", "hospital",
                "house_single", "houseboat", "igloo", "library", "lighthouse", "megalith", "monument", "museum", "nightclub", "obelisk", "parking_lot", "patio",
                "pergola", "pier", "pool", "porch", "portal", "pyramid", "restaurant", "rink", "rollercoaster", "roof", "ruins", "shed",
                "shipyard", "sidewalk", "silo", "skyscraper", "smokestack", "stadium", "stained_glass", "stairs", "statue", "storefront", "street", "structure",
                "theater", "tower", "train_station", "tunnel", "watermill", "wind_turbine", "windmill", "window"
            ]),
            (.vehicle, [
                "aircraft", "airplane", "airshow", "ambulance", "atv", "automobile", "backhoe", "balloon_hotair", "barge", "bicycle", "boat", "bulldozer",
                "bus", "cableway", "canoe", "car", "cart", "chairlift", "convertible", "conveyance", "crane_construction", "cruise_ship", "dashboard", "drone_machine",
                "engine_vehicle", "firetruck", "forklift", "formula_one_car", "go_kart", "grand_prix", "hangglider", "helicopter", "jeep", "jetski", "kayak", "limousine",
                "mast", "monorail", "motorcycle", "motorhome", "motorsport", "nascar", "police_car", "propeller", "railroad", "rickshaw", "rocket", "rowboat",
                "sailboat", "scooter", "semi_truck", "sled", "snowmobile", "speedboat", "sportscar", "streetcar", "submarine_water", "suv", "tire", "track_rail",
                "tractor", "train", "train_real", "tramway", "tricycle", "truck", "van", "vehicle", "wagon", "warship", "watercraft", "wheel",
                "wheelchair", "yacht"
            ]),
            (.plant, [
                "acorn", "begonia", "blossom", "bonsai", "bouquet", "branch", "cactus", "carnation", "christmas_tree", "chrysanthemum", "cilantro", "clover",
                "cornflower", "daffodil", "dahlia", "daisy", "dandelion", "decorative_plant", "eucalyptus_tree", "evergreen", "ferns", "flower", "flower_arrangement", "foliage",
                "grain", "grass", "herb", "holly", "ivy", "lily", "maple_tree", "marigold", "mistletoe", "moss", "oak_tree", "orchid",
                "palm_tree", "petunia", "plant", "poinsettia", "rice_field", "rose", "rosemary", "seaweed", "seed", "sequoia", "shrub", "snapdragon",
                "sunflower", "tree", "tulip", "vegetation", "willow"
            ]),
            (.indoor, [
                "accordion", "appliance", "armchair", "backgammon", "bath", "bathroom", "bathroom_faucet", "bathroom_room", "bed", "bedding", "bedroom", "billiards",
                "blender", "board_game", "bongo_drum", "bookshelf", "bowl", "brass_music", "cabinet", "calculator", "candle", "candlestick", "cassette", "cello",
                "chair", "chair_other", "chaise", "chandelier", "chess", "clarinet", "classroom", "closet", "computer", "computer_keyboard", "computer_monitor", "computer_mouse",
                "computer_tower", "consumer_electronics", "cookware", "crib", "cubicle", "cup", "curtain", "cutting_board", "dartboard", "decanter", "desk", "dice",
                "dining_room", "dishwasher", "diskette", "domino", "drinking_glass", "drum", "easel", "electric_fan", "fireplace", "flute", "folding_chair", "foosball",
                "furniture", "gamepad", "games", "grill", "guitar", "harp", "high_chair", "housewares", "interior_room", "interior_shop", "jacuzzi", "jar",
                "joystick", "juicer", "karaoke", "kettle", "kitchen", "kitchen_countertop", "kitchen_faucet", "kitchen_oven", "kitchen_room", "kitchen_sink", "lamp", "laptop",
                "laundry_machine", "light", "light_bulb", "living_room", "microphone", "microscope", "microwave", "mug", "musical_instrument", "office_supplies", "organ_instrument", "oven",
                "pan", "piano", "pillow", "plate", "play_card", "poker", "pot_cooking", "printer", "refrigerator", "roulette", "saxophone", "shower",
                "sofa", "speakers_music", "steamer_cookware", "stereo", "stool", "stove", "string_instrument", "swivel_chair", "table", "tableware", "tambourine", "teapot",
                "television", "toaster", "toaster_oven", "toilet_seat", "trombone", "trumpet", "tuba", "turntable", "ukulele", "vacuum", "vase", "videogame",
                "violin", "washbasin", "woodwind", "xylophone"
            ]),
            (.text, [
                "banner", "billboards", "book", "calendar", "chalkboard", "chart", "checkbook", "coupon", "credit_card", "currency", "diagram", "document",
                "envelope", "flipchart", "gift_card", "graffiti", "handwriting", "illustrations", "license_plate", "magazine", "map", "media", "money", "newspaper",
                "passport", "printed_page", "receipt", "red_envelope", "scoreboard", "screenshot", "sign", "sticky_note", "street_sign", "ticket", "whiteboard"
            ]),
            (.object, [
                "abacus", "anvil", "art", "atm", "axe", "backpack", "bag", "ball", "balloon", "barbell", "barrel", "baseball_bat",
                "basket_container", "bell", "bench", "binoculars", "birdhouse", "blocks", "bodyboard", "boot", "bottle", "briefcase", "broom", "bucket",
                "cage", "cakestand", "caliper", "camera", "car_seat", "cardboard_box", "carton", "cd", "chainsaw", "chopsticks", "christmas_decoration", "cigar",
                "cigarette", "circuit_board", "clock", "clothesline", "clothespin", "coin", "compass", "container", "cord", "corkscrew", "cosmetic_tool", "crate",
                "crutch", "decoration", "dial", "diaper", "diorama", "disco_ball", "doll", "dumbbell", "easter_egg", "extinguisher", "figurine", "firecracker",
                "fishbowl", "fishtank", "flag", "flagpole", "flashlight", "flipper", "footwear", "fork", "frame", "frisbee", "gas_mask", "gears",
                "gift", "glove", "glove_other", "goggles", "golf_ball", "golf_club", "grater", "hammer", "hammock", "headphones", "high_heel", "hookah",
                "horseshoe", "hourglass", "hurdle", "hydrant", "ice_skates", "iron_clothing", "jack_o_lantern", "jewelry", "jigsaw", "jug", "keg", "keypad",
                "kite", "knife", "ladle", "lamppost", "lantern", "leash", "lifejacket", "lifesaver", "lighter", "liquid", "luggage", "machine",
                "mailbox", "mallet", "manhole", "mask", "matches", "material", "measuring_tape", "medal", "medicine", "megaphone", "mop", "mousetrap",
                "mower", "oar", "optical_equipment", "origami", "pacifier", "paintbrush", "painting", "paper_bag", "payphone", "pen", "phone", "piggybank",
                "pipe", "pliers", "podium", "pole", "polka_dots", "porthole", "power_saw", "puck", "pulley", "puppet", "purse", "puzzles",
                "pylon", "pyrotechnics", "racquet", "rake", "rangoli", "ratchet", "raw_glass", "record", "rim", "road_safety_equipment", "rollerskates", "rolling_pin",
                "rope", "rotisserie", "sack", "saddle", "scarecrow", "scissors", "screwdriver", "seashell", "seat", "seesaw", "sewing", "shoes",
                "shopping_cart", "skateboard", "skeleton", "ski_boot", "ski_equipment", "skull", "slide_toy", "smoking_item", "sneaker", "snowboard", "snowshoe", "sock",
                "solar_panel", "sparkler", "spatula", "spoon", "sports_equipment", "spotlight", "sprinkler", "stethoscope", "stopwatch", "straw_drinking", "straw_hay", "stretcher",
                "stuffed_animals", "suitcase", "sundial", "surfboard", "swing_playground", "sword", "syringe", "tachometer", "telescope", "tent", "terrarium", "textile",
                "thermometer", "thermos", "thermostat", "tiara", "timepiece", "tool", "toolbox", "toy", "traffic_light", "train_toy", "trampoline", "trash_can",
                "treadmill", "tripod", "trophy", "typewriter", "umbrella", "utensil", "vehicle_toy", "wallet", "watch", "watering_can", "weight_scale", "wheelbarrow",
                "whisk", "winch", "wood_natural", "wood_processed", "wreath", "wrench", "yarn"
            ]),
        ]

        let mappedIdentifiers = groupedLabels.flatMap { $0.1 }
        assert(
            Set(mappedIdentifiers).count == mappedIdentifiers.count,
            "Vision identifier appears in multiple categories"
        )

        return groupedLabels.reduce(into: [String: AISubjectCategory]()) { result, group in
            for identifier in group.1 {
                result[identifier] = group.0
            }
        }
    }()
}
