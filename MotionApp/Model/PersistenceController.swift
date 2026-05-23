//
//  Persistence.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 07/10/25.
//

import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    // `container` é uma stored property de struct não-isolada. Não pode receber
    // `@MainActor`: stored properties só podem ser actor-isolated dentro de tipos
    // também isolated, senão o runtime aborta no swift_slowAlloc durante a
    // inicialização (EXC_BAD_ACCESS no launch).
    //
    // NSPersistentContainer em si é seguro de inicializar em qualquer thread;
    // só `viewContext` deve ser acessado da main (convenção runtime, não
    // isolation estática). As escritas continuam indo por contextos privados
    // (`newBackgroundContext()`), cada um com sua própria fila serial.
    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "SensorDataModel")
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Unresolved error \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
