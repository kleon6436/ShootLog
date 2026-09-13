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

    static func classify(
        _ image: CGImage,
        maxResults: Int = Self.maximumRawIdentifierCount
    ) -> VisionLabelClassification {
        guard maxResults > 0 else {
            return VisionLabelClassification(categories: [], rawIdentifiers: [])
        }

        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision1

        do {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
        } catch {
            return VisionLabelClassification(categories: [], rawIdentifiers: [])
        }

        guard let results = request.results else {
            return VisionLabelClassification(categories: [], rawIdentifiers: [])
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

    static let allMappedIdentifiers: Set<String> = Set(labelCategories.keys)

    private static let labelCategories: [String: AISubjectCategory] = {
        let groupedLabels: [(AISubjectCategory, [String])] = [
            (.person, [
                "acrobat", "adult", "apron", "athletics", "baby", "badminton", "ballet", "ballet_dancer", "baseball", "basketball", "bellydance", "bib",
                "bowling", "bowtie", "boxing", "breakdancing", "bride", "bridesmaid", "cheerleading", "child", "clothing", "clown", "concert", "conference",
                "costume", "cowboy_hat", "crowd", "cycling", "dancing", "deejay", "diving", "dressage", "earmuffs", "entertainer", "equestrian", "eyeglasses",
                "fedora", "fencing_sport", "fishing", "graduation", "groom", "gymnastics", "hardhat", "hat", "headgear", "helmet", "hiking", "hockey",
                "hoodie", "hula", "hunting", "jacket", "jeans", "jockey_horse", "juggling", "kickboxing", "kilt", "kimono", "lab_coat", "leotard",
                "loafer", "martial_arts", "military_uniform", "mitten", "moccasin", "motocross", "music", "necktie", "orchestra", "parade", "parasailing", "people",
                "performance", "ping_pong", "polo", "poncho", "putt", "rafting", "recreation", "rodeo", "rugby", "safety_vest", "samba", "santa_claus",
                "sari", "scarf", "singer", "skateboarding", "skiing", "snowboarding", "soccer", "sport", "stroller", "sumo", "sunglasses", "surfing",
                "swimsuit", "teen", "tennis", "tuxedo", "volleyball", "wedding", "wedding_dress", "workout", "wrestling", "yoga"
            ]),
            (.animal, [
                "adult_cat", "alligator_crocodile", "anchovy", "angelfish", "animal", "ant", "arachnid", "arthropods", "australian_shepherd", "barnacle", "barracuda", "basenji",
                "basset", "beagle", "bear", "bee", "beehive", "bernese_mountain", "bichon", "bird", "bison", "boar", "bobcat", "bulldog",
                "butterfly", "camel", "canine", "cat", "caterpillar", "cephalopod", "cetacean", "chameleon", "cheetah", "chihuahua", "chinchilla", "clownfish",
                "cockatoo", "collie", "cougar", "cow", "coyote_wolf", "crab", "dachshund", "dalmatian", "deer", "dinosaur", "doberman", "dog",
                "dolphin", "donkey", "dove", "dragonfly", "eagle", "elephant", "elk", "feline", "ferret", "fish", "flamingo", "fox",
                "frog", "gastropod", "gecko", "gerbil", "german_shepherd", "giraffe", "goat", "goldfish", "greyhound", "gull", "guppy", "hamster",
                "hedgehog", "heron", "hippopotamus", "horse", "hound", "hummingbird", "husky", "hyena", "iguana", "insect", "irish_wolfhound", "jack_russell_terrier",
                "jellyfish", "kangaroo", "kitten", "koala", "koi", "ladybug", "lemur", "leopard", "lion", "lionfish", "lizard", "llama",
                "lobster", "lynx", "malamute", "malinois", "mammal", "marsupial", "mastiff", "millipede", "mollusk", "monitor_lizard", "moose", "moth",
                "newfoundland", "ostrich", "otter", "owl", "oyster", "panda", "parakeet", "parrot", "peacock", "pelican", "penguin", "peregrine",
                "pig", "pigeon", "pitbull", "pomeranian", "poodle", "porcupine", "prairie_dog", "puffer_fish", "puffin", "pug", "python", "rabbit",
                "raccoon", "raptor", "rat", "rattlesnake", "raven", "reptile", "retriever", "rhinoceros", "ridgeback", "rodent", "roe", "rottweiler",
                "saint_bernard", "salmon", "sandpiper", "schnauzer", "scorpion", "seabass", "seahorse", "seal", "sealion", "setter", "shark", "sheep",
                "sheepdog", "shellfish", "skunk", "snail", "snake", "snake_other", "spaniel", "sparrow", "spider", "squirrel", "starfish", "stingray",
                "stork", "swan", "tiger", "toad", "tortoise", "toucan", "trout", "tuna", "turtle", "ungulates", "vizsla", "vulture",
                "walrus", "weimaraner", "whale", "woodpecker", "worm", "zebra", "zoo"
            ]),
            (.food, [
                "almond", "antipasti", "apple", "apricot", "artichoke", "arugula", "asparagus", "avocado", "bacon", "bagel", "baked_goods", "baklava",
                "banana", "bean", "beef", "beer", "beet", "bell_pepper", "berry", "birthday_cake", "biryani", "biscotti", "biscuit", "blackberry",
                "blueberry", "bread", "broccoli", "brownie", "bruschetta", "bubble_tea", "burrito", "butter", "cake", "cake_regular", "candy", "cantaloupe",
                "caprese", "caramel", "carrot", "cashew", "casserole", "celery", "cereal", "cheese", "cheesecake", "cherry", "chestnut", "chewing_gum",
                "chives", "chocolate", "chocolate_chip", "citrus_fruit", "cocktail", "coconut", "coffee", "coffee_bean", "coleslaw", "condiment", "cookie", "corn",
                "cranberry", "crepe", "croissant", "cucumber", "cupcake", "curry", "daikon", "dessert", "dill", "donut", "drink", "dumpling",
                "durian", "edamame", "egg", "eggplant", "falafel", "fig", "flan", "fondue", "food", "fried_chicken", "fried_egg", "fries",
                "frozen", "frozen_dessert", "fruit", "fruitcake", "garlic", "grape", "grapefruit", "green_beans", "grilled_chicken", "guacamole", "guava", "gyoza",
                "habanero", "ham", "hamburger", "honey", "honeydew", "hotdog", "hummus", "ice_cream", "jalapeno", "jello", "jelly", "juice",
                "juicer", "kebab", "kettle", "kiwi", "kohlrabi", "leek", "lemon", "lemongrass", "lime", "liquor", "lychee", "macadamia",
                "mandarine", "mango", "mangosteen", "margarita", "marshmallow", "martini", "matzo", "meat", "meatball", "melon", "milkshake", "mojito",
                "mushroom", "mustard", "naan", "nachos", "nectarine", "nut", "oatmeal", "omelet", "onion", "oranges", "paella", "pancake",
                "papaya", "passionfruit", "pasta", "pastry", "pea", "peach", "peanut", "pear", "pecan", "pepper_veggie", "pepperoni", "persimmon",
                "pickle", "pie", "pierogi", "pineapple", "pistachio", "pita", "pizza", "plum", "pomegranate", "popcorn", "popsicle", "potato",
                "poultry", "pretzel", "pudding", "pumpkin", "quesadilla", "quinoa", "radish", "rambutan", "ramen", "raspberry", "raw_glass", "red_wine",
                "rhubarb", "rice", "risotto", "salad", "salami", "samosa", "sandwich", "satay", "sauerkraut", "sausage", "scallop", "scrambled_eggs",
                "seafood", "shawarma", "smoothie", "soup", "spaghetti", "springroll", "steak", "stir_fry", "strawberry", "strudel", "sugar_cube", "sushi",
                "tableware", "taco", "taffy", "tapioca_pearls", "taro", "tea_drink", "tempura", "tequila", "teriyaki", "tiramisu", "tomato", "tortilla",
                "turmeric", "vegetable", "waffle", "wasabi", "watermelon", "wheat", "white_bread", "white_wine", "wine", "wonton", "yogurt", "yolk",
                "zucchini"
            ]),
            (.landscape, [
                "agriculture", "alley", "amusement_park", "archery", "aurora", "beach", "beekeeping", "bench", "billiards", "binoculars", "blizzard", "blue_sky",
                "bridge", "camping", "canyon", "cave", "cityscape", "cliff", "cloudy", "coral_reef", "creek", "daytime", "desert", "dirt_road",
                "embers", "fairground", "farm", "fire", "fireworks", "flame", "forest", "garden", "geyser", "glacier", "golf", "golf_course",
                "haze", "hill", "ice", "ice_skating", "iceberg", "island", "jungle", "kayak", "kiteboarding", "lake", "land", "lava",
                "lightning", "mangrove", "megalith", "moon", "mountain", "night_sky", "ocean", "orchard", "outdoor", "paintball", "parachute", "park",
                "path", "patio", "rainbow", "river", "road", "rock_climbing", "rocks", "sand", "sand_dune", "scuba", "shore", "sidewalk",
                "skatepark", "skating", "sky", "sledding", "snorkeling", "snow", "snowball", "snowman", "softball", "storm", "sun", "sunbathing",
                "sundial", "sunset_sunrise", "trail", "underwater", "vineyard", "volcano", "wakeboarding", "water", "water_body", "waterfall", "waterpolo", "watersport",
                "waterways", "wetland", "wind_turbine", "winter_sport"
            ]),
            (.building, [
                "airport", "apartment", "aquarium", "arch", "arena", "atm", "auditorium", "balcony", "bar", "barn", "bathroom", "bathroom_room",
                "bedroom", "bell", "belltower", "birdhouse", "bleachers", "blocks", "boathouse", "bodyboard", "brick", "brick_oven", "building", "carnival",
                "carousel", "casino", "castle", "cellar", "chimney", "circus", "classroom", "clock_tower", "closet", "dam", "deck", "dome",
                "domicile", "door", "driveway", "elevator", "escalator", "fence", "ferris_wheel", "fireplace", "fountain", "garage", "gargoyle", "gazebo",
                "grave", "greenhouse", "hangar", "harbour", "hospital", "house_single", "houseboat", "hydrant", "igloo", "interior_room", "interior_shop", "kitchen",
                "kitchen_room", "library", "lighthouse", "manhole", "monument", "museum", "nightclub", "obelisk", "parking_lot", "pergola", "pier",
                "pool", "porch", "portal", "porthole", "pyramid", "restaurant", "roof", "ruins", "sandcastle", "shed", "shipyard", "silo",
                "skyscraper", "smokestack", "stadium", "stained_glass", "stairs", "statue", "storefront", "street", "structure", "theater", "tower", "train_station",
                "tunnel", "watermill", "windmill", "window", "pole"
            ]),
            (.vehicle, [
                "aircraft", "airplane", "airshow", "ambulance", "atv", "automobile", "backhoe", "balloon", "balloon_hotair", "barge", "bicycle", "boat",
                "boot", "bottle", "bouquet", "bowl", "briefcase", "broom", "bucket", "bulldozer", "bullfighting", "bungee", "bus", "cableway",
                "cage", "cakestand", "caliper", "camera", "candy_cane", "canoe", "car", "car_seat", "cart", "chairlift", "convertible", "conveyance",
                "crane_construction", "cruise_ship", "dock", "drone_machine", "engine_vehicle", "firetruck", "forklift", "formula_one_car", "go_kart", "hangglider", "helicopter", "jeep",
                "jetski", "limousine", "mast", "monorail", "motorcycle", "motorhome", "nascar", "oar", "police_car", "propeller", "railroad", "rickshaw",
                "road_other", "rocket", "rollercoaster", "rollerskates", "rowboat", "sailboat", "scooter", "semi_truck", "shopping_cart", "skateboard", "sled", "snowmobile",
                "snowshoe", "speedboat", "sportscar", "streetcar", "submarine_water", "surfboard", "suv", "tire", "track_rail", "tractor", "traffic_light", "train",
                "train_real", "train_toy", "tramway", "tricycle", "truck", "van", "vehicle", "vehicle_toy", "wagon", "warship", "watercraft", "wheel",
                "wheelbarrow", "wheelchair", "windsurfing", "yacht"
            ]),
            (.plant, [
                "acorn", "begonia", "blossom", "bonsai", "branch", "cactus", "candy_other", "cardboard_box", "carnation", "carton", "cauliflower", "celebration",
                "celestial_body", "celestial_body_other", "centipede", "ceremony", "chainsaw", "chopsticks", "christmas_decoration", "christmas_tree", "chrysanthemum", "cigar", "cigarette", "cilantro",
                "circuit_board", "clam", "cloak", "clover", "coin", "compass", "conch", "cord", "corgi", "corkscrew", "cornflower", "cosmetic_tool",
                "crate", "cricket_sport", "crosswalk", "crutch", "daffodil", "dahlia", "daisy", "dandelion", "dartboard", "decanter", "decorative_plant", "diaper",
                "dice", "doll", "domino", "dragon_parade", "drum", "dumbbell", "easter_egg", "eucalyptus_tree", "evergreen", "extinguisher", "ferns", "figurine",
                "firecracker", "fishbowl", "fishtank", "flagpole", "flashlight", "flower", "flower_arrangement", "foliage", "grain", "grass", "herb", "holly",
                "ivy", "lily", "maple_tree", "marigold", "mistletoe", "moss", "oak_tree", "orchid", "palm_tree", "petunia", "plant", "poinsettia",
                "rice_field", "rose", "rosemary", "seaweed", "seed", "sequoia", "shrub", "snapdragon", "spinach", "sunflower", "sunflower_seeds", "tree",
                "tulip", "vegetation", "watering_can", "willow"
            ]),
            (.indoor, [
                "anvil", "appliance", "armchair", "backgammon", "bath", "bathrobe", "bathroom_faucet", "bed", "bedding", "blender", "board_game", "bongo_drum",
                "bookshelf", "brass_music", "cabinet", "calculator", "candle", "candlestick", "cassette", "cello", "chair", "chair_other", "chaise", "chandelier",
                "chess", "clarinet", "clothesline", "clothespin", "computer", "computer_keyboard", "computer_monitor", "computer_mouse", "computer_tower", "consumer_electronics", "container", "cookware",
                "crib", "cubicle", "cup", "curtain", "cutting_board", "desk", "dining_room", "dishwasher", "diskette", "drinking_glass", "easel", "electric_fan",
                "flipper", "flute", "folding_chair", "foosball", "football", "furniture", "gamepad", "games", "grill", "guitar", "harp", "high_chair",
                "jacuzzi", "jar", "karaoke", "kitchen_countertop", "kitchen_faucet", "kitchen_oven", "kitchen_sink", "lamp", "laptop", "laundry_machine", "light", "light_bulb",
                "mailbox", "microphone", "microscope", "microwave", "office_supplies", "organ_instrument", "oven", "pan", "piano", "plate", "refrigerator", "saxophone",
                "shower", "sofa", "speakers_music", "stereo", "stove", "table", "television", "toaster", "toaster_oven", "toilet_seat", "toolbox", "trumpet",
                "tuba", "vacuum", "vase", "washbasin", "living_room"
            ]),
            (.text, [
                "abacus", "accordion", "art", "axe", "backpack", "bag", "ball", "ballgames", "banner", "barbell", "barrel", "baseball_bat",
                "baseball_hat", "basket_container", "beanie", "billboards", "book", "calendar", "cd", "chalkboard", "chart", "checkbook", "clock", "coupon",
                "credit_card", "currency", "dashboard", "decoration", "diagram", "dial", "diorama", "disco_ball", "document", "envelope", "flag", "flipchart",
                "gift", "gift_card", "graffiti", "handwriting", "hourglass", "illustrations", "jigsaw", "joystick", "keypad", "license_plate", "magazine", "map",
                "medal", "media", "megaphone", "money", "musical_instrument", "newspaper", "origami", "painting", "paper_bag", "passport", "pen", "phone",
                "play_card", "podium", "polka_dots", "printed_page", "printer", "puppet", "puzzles", "rangoli", "receipt", "record", "red_envelope", "roulette", "frame",
                "scoreboard", "screenshot", "sewing", "sign", "skeleton", "solar_panel", "sticky_note", "street_sign", "tachometer", "tattoo", "telescope",
                "textile", "thermometer", "thermos", "thermostat", "ticket", "timepiece", "trophy", "typewriter", "ukulele", "violin", "wallet", "watch",
                "whiteboard", "woodwind", "xylophone", "yarn"
            ]),
            (.object, [
                "footwear", "fork", "frisbee", "gas_mask", "gears", "gingerbread", "glove", "glove_other", "goggles", "golf_ball", "golf_club",
                "gown", "grand_prix", "grater", "hammer", "hammock", "headphones", "health_club", "henna", "high_heel", "hookah", "horseshoe", "housewares",
                "hurdle", "ice_skates", "iron_clothing", "jack_o_lantern", "jewelry", "jug", "keg", "kite", "knife", "ladle", "lamppost", "lantern",
                "leash", "lettuce", "lifejacket", "lifesaver", "lighter", "liquid", "lollipop", "luggage", "machine", "mackerel", "mallet", "mask",
                "matches", "material", "measuring_tape", "medicine", "mop", "motorsport", "mousetrap", "mower", "muffin", "mug", "mussel", "nest",
                "optical_equipment", "pacifier", "paintbrush", "payphone", "piggybank", "pillow", "pipe", "playground", "pliers", "poker", "pot_cooking",
                "power_saw", "puck", "pulley", "purse", "pylon", "pyrotechnics", "racquet", "rake", "ratchet", "rim", "rink", "road_safety_equipment",
                "rollerskating", "rolling_pin", "rope", "rotisserie", "sack", "saddle", "sangria", "sardine", "scarab", "scarecrow", "scissors", "scone",
                "screwdriver", "seashell", "seasonings", "seat", "seesaw", "sesame", "shellfish_prepared", "shoes", "ski_boot", "ski_equipment", "skull", "skydiving",
                "slide_toy", "smoking_item", "snapper", "sneaker", "snowboard", "sock", "soda", "sombrero", "souffle", "souvlaki", "spareribs", "sparkler",
                "sparkling_wine", "spatula", "spice", "spiderweb", "spoon", "sports_equipment", "spotlight", "sprinkler", "squash_sport", "starfruit", "steamer_cookware", "stethoscope",
                "stool", "stopwatch", "straw_drinking", "straw_hay", "stretcher", "string_instrument", "stuffed_animals", "suit", "suitcase", "sunfish", "sunhat", "swimming",
                "swing_playground", "swivel_chair", "sword", "swordfish", "syringe", "tabbouleh", "tambourine", "tapas", "teapot", "tent", "terrarium", "terrier",
                "thunderstorm", "tiara", "tool", "tornado", "toy", "trampoline", "trash_can", "treadmill", "tripod", "trombone", "turntable", "umbrella",
                "urchin", "utensil", "videogame", "wedding_cake", "weight_scale", "wetsuit", "whisk", "winch", "wine_bottle", "wood_natural", "wood_processed", "wreath",
                "wrench"
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
