module todolist_addr::todolist{
    use std::signer;
    use std::string::String;
    use std::event;
    use std::table as T;
    
    #[test_only]
    use initia_std::string;

    #[test_only]
    use initia_std::table;
    
     // Errors
    const E_NOT_INITIALIZED: u64 = 1;
    const ETASK_DOESNT_EXIST: u64 = 2;
    const ETASK_IS_COMPLETED: u64 = 3;

    struct TodoList has key {
        tasks: T::Table<u64, Task>,
        set_task_event: event::EventHandle<Task>,
        task_counter: u64
    }

    struct Task has store, drop, copy {
        task_id: u64,
        address: address,
        content: String,
        completed: bool,
    }  

    public entry fun create_list(account: &signer){
        let todo_list = TodoList {
            tasks: T::new(),
            set_task_event: event::new_event_handle<Task>(account),
            task_counter: 0
        };
        // move the TodoList resource under the signer account
        move_to(account, todo_list);
    }

    public entry fun create_task(account: &signer, content: String) acquires TodoList {
        // gets the signer address
        let signer_address = signer::address_of(account);
        // assert signer has created a list
        assert!(exists<TodoList>(signer_address), E_NOT_INITIALIZED);
        // gets the TodoList resource
        let todo_list = borrow_global_mut<TodoList>(signer_address);
        // increment task counter
        let counter = todo_list.task_counter + 1;
        // creates a new Task
        let new_task = Task {
            task_id: counter,
            address: signer_address,
            content,
            completed: false
        };
        // adds the new task into the tasks table
        T::upsert(&mut todo_list.tasks, counter, new_task);
        // sets the task counter to be the incremented counter
        todo_list.task_counter = counter;
        // fires a new task created event
        event::emit_event<Task>(
        &mut borrow_global_mut<TodoList>(signer_address).set_task_event,
        new_task,
        );
    }

    public entry fun complete_task(account: &signer, task_id: u64) acquires TodoList {
        // gets the signer address
        let signer_address = signer::address_of(account);
            // assert signer has created a list
        assert!(exists<TodoList>(signer_address), E_NOT_INITIALIZED);
        // gets the TodoList resource
        let todo_list = borrow_global_mut<TodoList>(signer_address);
        // assert task exists
        assert!(T::contains(&todo_list.tasks, task_id), ETASK_DOESNT_EXIST);
        // gets the task matched the task_id
        let task_record = T::borrow_mut(&mut todo_list.tasks, task_id);
        // assert task is not completed
        assert!(task_record.completed == false, ETASK_IS_COMPLETED);
        // update task as completed
        task_record.completed = true;
    }

    #[test(admin = @0x123)]
    public entry fun test_flow(admin: signer) acquires TodoList {
        // initialize contract with admin account 
        create_list(&admin);

        // creates a task by the admin account
        create_task(&admin, string::utf8(b"New Task"));
        let task_count = event::counter(&borrow_global<TodoList>(signer::address_of(&admin)).set_task_event);       
        assert!(task_count == 1, 4);
        let todo_list = borrow_global<TodoList>(signer::address_of(&admin));
        assert!(todo_list.task_counter == 1, 5);
        let task_record = T::borrow(&todo_list.tasks, todo_list.task_counter);
        assert!(task_record.task_id == 1, 6);
        assert!(task_record.completed == false, 7);
        assert!(task_record.content == string::utf8(b"New Task"), 8);
        assert!(task_record.address == signer::address_of(&admin), 9);

        // updates task as completed
        complete_task(&admin, 1);
        let todo_list = borrow_global<TodoList>(signer::address_of(&admin));
        let task_record = table::borrow(&todo_list.tasks, 1);
        assert!(task_record.task_id == 1, 10);
        assert!(task_record.completed == true, 11);
        assert!(task_record.content == string::utf8(b"New Task"), 12);
        assert!(task_record.address == signer::address_of(&admin), 13);
    }

    #[test(admin = @0x123)]
    #[expected_failure(abort_code = E_NOT_INITIALIZED)]
    public entry fun account_can_not_update_task(admin: signer) acquires TodoList {
        // account can not toggle task as no list was created
        complete_task(&admin, 2);
    }
}