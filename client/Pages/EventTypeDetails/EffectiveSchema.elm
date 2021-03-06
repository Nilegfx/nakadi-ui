module Pages.EventTypeDetails.EffectiveSchema exposing (..)

import Helpers.JsonEditor exposing (..)
import Stores.EventType exposing (compatibilityModes)


{-|
 Transform the user provided schema to the real effective schema.
-}
toEffective : Bool -> String -> Maybe String -> JsonValue -> JsonValue
toEffective show category mode schema =
    if show then
        toStrict mode <|
            case category of
                "business" ->
                    insertMetadata schema

                "data" ->
                    wrapSchema schema

                _ ->
                    schema
    else
        schema


toStrict : Maybe String -> JsonValue -> JsonValue
toStrict mode schema =
    if mode == Just compatibilityModes.compatible then
        enforceStrict schema
    else
        showAdditional schema


{-|
   Convert a user provided schema to Data Effective schema
   using the same algorithm as in Nakadi
   https://nakadi.io/manual.html#event-type-schema-and-effective-schema
   https://github.com/zalando/nakadi/blob/master/src/main/java/org/zalando/nakadi/validation/JsonSchemaEnrichment.java#L111
-}
wrapSchema : JsonValue -> JsonValue
wrapSchema schema =
    let
        dataCategoryJson =
            """
            {
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "metadata": {
                    },
                    "data": {
                    },
                    "data_type": {
                        "summary": "Data or Resource type",
                        "type": "string",
                        "example": "pennybags:order"
                    },
                    "data_op": {
                        "summary": "The type of operation executed on the entity.",
                        "description": "\\n C: Creation \\n U: Update \\n D: Deletion \\n S: Snapshot",
                        "type": "string",
                        "enum": ["C", "U", "D", "S"]
                    }
                },
                "required": ["data_type", "data_op", "data"]
            }

            """
                |> stringToJsonValue
                |> Result.withDefault ValueNull

        schemaDefinitions =
            schema |> jsonValueGet "definitions"

        schemaWithoutDefinitions =
            schema |> jsonValueDelete "definitions"

        properties =
            dataCategoryJson
                |> jsonValueGet "properties"
                |> Maybe.withDefault (ValueObject [])
                |> jsonValueSet "data" schemaWithoutDefinitions

        trySetDefinitions schema =
            case schemaDefinitions of
                Nothing ->
                    schema

                Just definitions ->
                    schema
                        |> jsonValueSet "definitions" definitions
    in
        dataCategoryJson
            |> jsonValueSet "properties" properties
            |> insertMetadata
            |> trySetDefinitions


{-|
 Insert metadata field to the root properties level.
 https://nakadi.io/manual.html#definition_EventMetadata
 https://github.com/zalando/nakadi/blob/master/src/main/java/org/zalando/nakadi/validation/JsonSchemaEnrichment.java#L142
-}
insertMetadata : JsonValue -> JsonValue
insertMetadata schema =
    let
        metadata =
            """
            {
                "type": "object",
                "properties": {
                    "eid": {
                        "summary": "Identifier of this Event.",
                        "description": "Clients MUST generate this value and it SHOULD be guaranteed to be unique from the\\n perspective of the producer. Consumers MIGHT use this value to assert uniqueness of\\n reception of the Event.",
                        "type": "string",
                        "format": "uuid",
                        "example": "105a76d8-db49-4144-ace7-e683e8f4ba46"

                    },
                    "event_type": {
                        "summary": "The EventType of this Event.",
                        "description": "This is enriched by Nakadi on reception of the Event\\nbased on the endpoint where the Producer sent the Event to.\\n If provided MUST match the endpoint. Failure to do so will cause rejection of the Event.",
                        "type": "string",
                        "example": "pennybags.payment-business-event"
                    },
                    "occurred_at": {
                        "summary": "Timestamp of creation of the Event.",
                        "description": "Timestamp of creation generated by the producer.",
                        "type": "string",
                        "format": "RFC 3339 date-time",
                        "example": "1996-12-19T16:39:57-08:00"
                    },
                    "parent_eids": {
                        "type": "array",
                        "items": {
                            "summary": "Event that caused this Event.",
                            "description": "Event identifier of the Event that caused the generation of this Event.\\n Set by the producer.",
                            "type": "string",
                            "format": "uuid",
                            "example": "205a76d8-db49-4144-ace7-e683e8f4ba42"
                        }
                    },
                    "flow_id": {
                        "summary": "The flow-id of the producer of this Event.",
                        "description": "As this is usually a HTTP header, this is\\n enriched from the header into the metadata by Nakadi to avoid clients having to\\n explicitly copy this.",
                        "type": "string",
                        "example": "JAh6xH4OQhCJ9PutIV_RYw"
                    },
                    "partition": {
                        "summary": "Indicates the partition assigned to this Event.",
                        "description": "Required to be set by the client if partition strategy of the EventType is\\n 'user_defined'.",
                        "type": "string",
                        "example": "0"
                    },
                    "version": {
                        "summary": "Version of the schema used for validating this event. ",
                        "description": "This is enriched upon reception.\\n This string uses semantic versioning, which is better defined in the EventTypeSchema object.",
                        "example": "1.5.3",
                        "readOnly": true
                    },
                    "received_at": {
                        "summary": "Timestamp of the reception of the Event by Nakadi.",
                        "description": "This is enriched upon reception of the Event.\\n If set by the producer Event will be rejected.",
                        "type": "string",
                        "format": "RFC 3339 date-time",
                        "example": "1996-12-19T16:39:57-08:00",
                        "readOnly": true
                    }
                },
                "required": ["eid", "occurred_at"],
                "additionalProperties": false
            }
            """
                |> stringToJsonValue
                |> Result.mapError (Debug.log "Can't parse metadata template")
                |> Result.withDefault ValueNull

        properties =
            schema
                |> jsonValueGet "properties"
                |> Maybe.withDefault (ValueObject [])
                |> jsonValueSetFirst "metadata" metadata

        required =
            schema
                |> jsonValueGet "required"
                |> \obj ->
                    case obj of
                        Just (ValueArray list) ->
                            ValueArray ((ValueString "metadata") :: list)

                        _ ->
                            ValueArray [ ValueString "metadata" ]
    in
        schema
            |> jsonValueSet "properties" properties
            |> jsonValueSet "required" required


{-|
  Set additionalProperties:false for properties on every level.
  https://github.com/zalando/nakadi/blob/master/src/main/java/org/zalando/nakadi/validation/JsonSchemaEnrichment.java#L43
-}
enforceStrict : JsonValue -> JsonValue
enforceStrict value =
    let
        insertAdditionalProperties obj =
            if has "properties" obj then
                obj
                    |> List.filter (\( k, v ) -> k /= "additionalProperties")
                    |> (::) ( "additionalProperties", ValueBool False )
            else
                obj

        insertAdditionalItems obj =
            if has "items" obj then
                obj
                    |> List.filter (\( k, v ) -> k /= "additionalItems")
                    |> (::) ( "additionalItems", ValueBool False )
            else
                obj
    in
        case value of
            ValueObject obj ->
                obj
                    |> insertAdditionalProperties
                    |> insertAdditionalItems
                    |> List.map (\( k, v ) -> ( k, enforceStrict v ))
                    |> ValueObject

            _ ->
                value


{-|
    Set additionalProperties:true (if it was not set before) to
    explicitly show that properties can be extended.
-}
showAdditional : JsonValue -> JsonValue
showAdditional value =
    let
        insertAdditionalProperties obj =
            if
                (has "properties" obj)
                    && not (has "additionalProperties" obj)
            then
                obj
                    |> (::) ( "additionalProperties", ValueBool True )
            else
                obj

        insertAdditionalItems obj =
            if
                (has "items" obj)
                    && not (has "additionalItems" obj)
            then
                obj
                    |> (::) ( "additionalItems", ValueBool True )
            else
                obj
    in
        case value of
            ValueObject obj ->
                obj
                    |> insertAdditionalProperties
                    |> insertAdditionalItems
                    |> List.map (\( k, v ) -> ( k, showAdditional v ))
                    |> ValueObject

            _ ->
                value


has : String -> List ( String, JsonValue ) -> Bool
has key list =
    list
        |> List.filter (\( k, v ) -> k == key)
        |> List.length
        |> (/=) 0
