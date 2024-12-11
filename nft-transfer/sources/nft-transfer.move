// cosmos::nft_transfer wrapper module for hook module
module nft_transfer::nft_transfer {
    use std::string::String;

    use initia_std::object::Object;
    use initia_std::cosmos;
    use initia_std::collection::Collection;

    public entry fun nft_transfer(
        sender: &signer,
        receiver: String,
        collection: Object<Collection>,
        token_ids: vector<String>,
        source_port: String,
        source_channel: String,
        revision_number: u64,
        revision_height: u64,
        timeout_timestamp: u64,
        memo: String
    ) {
        cosmos::nft_transfer(
            sender,
            receiver,
            collection,
            token_ids,
            source_port,
            source_channel,
            revision_number,
            revision_height,
            timeout_timestamp,
            memo
        );
    }
}
