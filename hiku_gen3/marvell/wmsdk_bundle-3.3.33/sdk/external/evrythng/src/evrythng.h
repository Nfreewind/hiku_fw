/**
 *
 * @file   evrythng.h
 * @brief  Evrythng library interface.
 *
 **/

#ifndef _EVRYTHNG_H
#define _EVRYTHNG_H

#include <stdint.h>

/************************************************
 *              EVRYTHNG DATA TYPES
 ***********************************************/

/** @brief All possible return values of function calls.
 */
typedef enum {
    EVRYTHNG_CONNECTION_LOST = 0,
    EVRYTHNG_CONNECTION_RESTORED = 1,
} evrythng_connection_status_e;


/** @brief Callback prototype used to notify
 *         user about connection lost/restored event.
 *         WARNING: do not call any EVT cloud related functions here,
 *         one can set app specific flags or launch async routines.
 *         The callback is called before library tries to reconnect with
 *         EVRYTHNG_CONNECTION_LOST argument and after successfull reconnection
 *         with EVRYTHNG_CONNECTION_RESTORED.
 */
typedef void connection_status_callback(evrythng_connection_status_e status);

/** @brief All possible return values of function calls.
*/
typedef enum {
    EVRYTHNG_SUCCESS = 0,
    EVRYTHNG_FAILURE = -1,
} evrythng_return_e;

/** @brief Structure to use with @c EvrythngConfigure() to
 *  	   configure the Evrythng client.
 */
typedef struct {
    const char* url;
    const char* api_key;
    const char* client_id;
#if defined (OPENSSL) || defined (TLSSOCKET)
    const char* tls_server_uri;
    const char* cert_buffer;
    int         cert_buffer_size;
    uint8_t     enable_ssl:1;
#endif
    connection_status_callback* connection_status_cb;
} evrythng_config_t;

/** @brief Callback prototype used for subscribe functions,
 *  	   which is called on message arrival from the Evrythng
 *  	   cloud.
 */
typedef void sub_callback(jobj_t *json_obj);

/** @brief Callback prototype used for publish functions,
 *  	   which is called on message delivered event from the
 *  	   Evrythng cloud.
 */
typedef void pub_callback(void);

/************************************************
 *              EVRYTHNG FUNCTIONS
 ***********************************************/

/** @brief Configure the Evrythng Client.
 *
 * Use this function to set Evrythng client configuration and connect to the Evrythng cloud.
 *
 * @param[in] config    Structure which contains Evrythng client configuration
 *                      used for connecting to the Evrythng cloud.
 *
 * @return    Indicates whether the configuration was accepted and the client was successfully
 *            connected to the Evrythng cloud.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngConfigure(evrythng_config_t* config);

/** @brief Subscribe a client to a single property of the thing.
 *
 * This function attempts to subscribe a client to a single property of the thing.
 *  
 * @param[in] thng_id       A thing ID.
 * @param[in] property_name The name of the property. 
 * @param[in] pub_states    The pubStates flag. 
 * @param[in] qos           The requested quality of service for the subscription.
 * @param[in] callback      A pointer to a subscribe callback function. 
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubThngProperty(char* thng_id, char* property_name, int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from a single property of the
 *  	   thing.
 *
 * This function attempts to unsubscribe a client from a single
 * property of the thing. 
 *  
 * @param[in] thng_id       A thing ID.
 * @param[in] property_name The name of the property. 
 * @param[in] pub_states    The pubStates flag. 
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubThngProperty(char* thng_id, char* property_name, int pub_states);

/** @brief Subscribe a client to all properties of the thing.
 * 
 * This function attempts to subscribe a client to all properties of the thing.
 *
 * @param[in] thng_id    A thing ID. 
 * @param[in] pub_states The pubStates flag. 
 * @param[in] qos        The requested quality of service for the subscription.
 * @param[in] callback   A pointer to a subscribe callback function.
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubThngProperties(char* thng_id, int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from all properties of the
 *  	   thing.
 * 
 * This function attempts to unsubscribe a client from all 
 * properties of the thing. 
 *
 * @param[in] thng_id    A thing ID. 
 * @param[in] pub_states The pubStates flag. 
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubThngProperties(char* thng_id, int pub_states);

/** @brief Publish a single property to a given thing.
 *
 * This function attempts to publish a single property to a given thing.
 *
 * @param[in] thng_id A     A thing ID.
 * @param[in] property_name The name of the property.
 * @param[in] property_json A JSON string which contains property value. 
 * @param[in] qos           The qos of the message. 
 * @param[in] callback      A pointer to a publish callback function.
 * 
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubThngProperty(char* thng_id, char* property_name, char* property_json, int qos, pub_callback *callback);

/** @brief Publish a few properties to a given thing.
 *
 * This function attempts to publish a few properties to a given thing.
 *
 * @param[in] thng_id         A thing ID.
 * @param[in] properties_json A JSON string which contains properties values. 
 * @param[in] qos             The qos of the message. 
 * @param[in] callback        A pointer to a publish callback function. 
 *
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubThngProperties(char* thng_id, char* properties_json, int qos, pub_callback *callback);

/** @brief Subscribe a client to a single action of the thing.
 *
 * This function attempts to subscribe a client to a single action of the thing.
 *
 * @param[in] thng_id     A thing ID.
 * @param[in] action_name The name of an action. 
 * @param[in] pub_states  The pubStates flag.
 * @param[in] qos         The requested quality of service for the subscription.
 * @param[in] callback    A pointer to a subscribe callback function. 
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubThngAction(char* thng_id, char* action_name, int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from a single action of the
 *  	   thing.
 *
 * This function attempts to unsubscribe a client from a single 
 * action of the thing. 
 *
 * @param[in] thng_id     A thing ID.
 * @param[in] action_name The name of an action. 
 * @param[in] pub_states  The pubStates flag.
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubThngAction(char* thng_id, char* action_name, int pub_states);

/** @brief Subscribe a client to all actions of the thing.
 *
 * This function attempts to subscribe a client to all actions of the thing.
 *
 * @param[in] thng_id    A thing ID. 
 * @param[in] pub_states The pubStates flag.
 * @param[in] qos        The requested quality of service for the subscription. 
 * @param[in] callback   A pointer to a subscribe callback function. 
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubThngActions(char* thng_id, int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from all actions of the thing.
 *
 * This function attempts to unsubscribe a client from all 
 * actions of the thing. 
 *
 * @param[in] thng_id    A thing ID. 
 * @param[in] pub_states The pubStates flag.
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubThngActions(char* thng_id, int pub_states);

/** @brief Publish a single action to a given thing. 
 *
 * This function attempts to publish a single action to a given thing. 
 *
 * @param[in] thng_id     A thing ID.
 * @param[in] action_name The name of an action.
 * @param[in] action_json A JSON string which contains an action. 
 * @param[in] qos         The qos of the message. 
 * @param[in] callback    A pointer to a publish callback function. 
 *
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubThngAction(char* thng_id, char* action_name, char* action_json, int qos, pub_callback *callback);

/** @brief Publish a few actions to a given thing.
 *
 * This function attempts to publish a few actions to a given thing.
 *
 * @param[in] thng_id      A thing ID.
 * @param[in] actions_json A JSON string which contains actions. 
 * @param[in] qos          The qos of the message. 
 * @param[in] callback     A pointer to a publish callback function. 
 *
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubThngActions(char* thng_id, char* actions_json, int qos, pub_callback *callback);

/** @brief Subscribe a client to a location of the thing.
 *
 * This function attempts to subscribe a client to a location of the thing.
 *
 * @param[in] thng_id    A thing ID. 
 * @param[in] pub_states The pubStates flag.
 * @param[in] qos        The requested quality of service for the subscription. 
 * @param[in] callback   A pointer to a subscribe callback function. 
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubThngLocation(char* thng_id, int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from a location of the thing.
 *
 * This function attempts to unsubscribe a client from a 
 * location of the thing. 
 *
 * @param[in] thng_id    A thing ID. 
 * @param[in] pub_states The pubStates flag.
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubThngLocation(char* thng_id, int pub_states);

/** @brief Publish a location to a given thing.
 *
 * This function attempts to publish a location to a given thing.
 *
 * @param[in] thng_id       A thing ID.
 * @param[in] location_json A JSON string which contains location. 
 * @param[in] qos           The qos of the message. 
 * @param[in] callback      A pointer to a publish callback function. 
 *
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubThngLocation(char* thng_id, char* location_json, int qos, pub_callback *callback);

/** @brief Subscribe a client to a single property of the product.
 *
 * This function attempts to subscribe a client to a single property of the product.
 *
 * @param[in] products_id   A product ID.
 * @param[in] property_name The name of the property. 
 * @param[in] pub_states    The pubStates flag.
 * @param[in] qos           The requested quality of service for the subscription.
 * @param[in] callback      A pointer to a subscribe callback function. 
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubProductProperty(char* products_id, char* property_name, int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from a single property of the
 *  	   product.
 *
 * This function attempts to unsubscribe a client from a single 
 * property of the product. 
 *
 * @param[in] products_id   A product ID.
 * @param[in] property_name The name of the property. 
 * @param[in] pub_states    The pubStates flag.
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubProductProperty(char* products_id, char* property_name, int pub_states);

/** @brief Subscribe a client to all properties of the product.
 *
 * This function attempts to subscribe a client to all properties of the product.
 *
 * @param[in] products_id A product ID. 
 * @param[in] pub_states  The pubStates flag.
 * @param[in] qos         The requested quality of service for the subscription.
 * @param[in] callback    A pointer to a subscribe callback function. 
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubProductProperties(char* products_id, int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from all properties of the
 *  	   product.
 *
 * This function attempts to unsubscribe a client from all 
 * properties of the product. 
 *
 * @param[in] products_id A product ID. 
 * @param[in] pub_states  The pubStates flag.
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubProductProperties(char* products_id, int pub_states);

/** @brief Publish a single property to a given product.
 *
 * This function attempts to publish a single property to a given product.
 *
 * @param[in] products_id   A product ID.
 * @param[in] property_name The name of the property.
 * @param[in] property_json A JSON string which contains property value. 
 * @param[in] qos           The qos of the message. 
 * @param[in] callback      A pointer to a publish callback function. 
 *
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubProductProperty(char* products_id, char* property_name, char* property_json, int qos, pub_callback *callback);

/** @brief Publish a few properties to a given product.
 *
 * This function attempts to publish a few properties to a given product.
 *
 * @param[in] products_id     A product ID.
 * @param[in] properties_json A JSON string which contains properties values. 
 * @param[in] qos             The qos of the message. 
 * @param[in] callback        A pointer to a publish callback function. 
 *
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubProductProperties(char* products_id, char* properties_json, int qos, pub_callback *callback);

/** @brief Subscribe a client to a single action of the product.
 *
 * This function attempts to subscribe a client to a single action of the product.
 *
 * @param[in] products_id A product ID.
 * @param[in] action_name The name of an action. 
 * @param[in] pub_states  The pubStates flag.
 * @param[in] qos         The requested quality of service for the subscription.
 * @param[in] callback    A pointer to a subscribe callback function. 
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubProductAction(char* products_id, char* action_name, int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from a single action of the
 *  	   product.
 *
 * This function attempts to unsubscribe a client from a single 
 * action of the product. 
 *
 * @param[in] products_id A product ID.
 * @param[in] action_name The name of an action. 
 * @param[in] pub_states  The pubStates flag.
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubProductAction(char* products_id, char* action_name, int pub_states);

/** @brief Subscribe a client to all actions of the product.
 *
 * This function attempts to subscribe a client to all actions of the product.
 *
 * @param[in] products_id A product ID. 
 * @param[in] pub_states  The pubStates flag.
 * @param[in] qos         The requested quality of service for the subscription.
 * @param[in] callback    A pointer to a subscribe callback function. 
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubProductActions(char* products_id, int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from all actions of the product.
 *
 * This function attempts to unsubscribe a client from all 
 * actions of the product. 
 *
 * @param[in] products_id A product ID. 
 * @param[in] pub_states  The pubStates flag.
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubProductActions(char* products_id, int pub_states);

/** @brief Publish a single action to a given product.
 *
 * This function attempts to publish a single action to a given product. 
 *
 * @param[in] products_id A product ID.
 * @param[in] action_name The name of an action.
 * @param[in] action_json A JSON string which contains an action. 
 * @param[in] qos         The qos of the message. 
 * @param[in] callback    A pointer to a publish callback function. 
 *
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubProductAction(char* products_id, char* action_name, char* action_json, int qos, pub_callback *callback);

/** @brief Publish a few actions to a given product.
 *
 * This function attempts to publish a few actions to a given product.
 *
 * @param[in] products_id  A product ID.
 * @param[in] actions_json A JSON string which contains actions. 
 * @param[in] qos          The qos of the message. 
 * @param[in] callback     A pointer to a publish callback function. 
 *
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubProductActions(char* products_id, char* actions_json, int qos, pub_callback *callback);

/** @brief Subscribe a client to a single action.
 *
 * This function attempts to subscribe a client to a single action.
 *
 * @param[in] action_name The name of an action. 
 * @param[in] pub_states  The pubStates flag.
 * @param[in] qos         The requested quality of service for the subscription.
 * @param[in] callback    A pointer to a subscribe callback function. 
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubAction(char* action_name, int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from a single action.
 *
 * This function attempts to unsubscribe a client from a single 
 * action. 
 *
 * @param[in] action_name The name of an action. 
 * @param[in] pub_states  The pubStates flag.
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubAction(char* action_name, int pub_states);

/** @brief Subscribe a client to all actions.
 *
 * This function attempts to subscribe a client to all actions.
 *  
 * @param[in] pub_states The pubStates flag.
 * @param[in] qos        The requested quality of service for the subscription. 
 * @param[in] callback   A pointer to a subscribe callback function. 
 *
 * @return    Indicates whether the subscription request is successful.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngSubActions(int pub_states, int qos, sub_callback *callback);

/** @brief Unsubscribe a client from all actions.
 *
 * This function attempts to unsubscribe a client from all 
 * actions. 
 *  
 * @param[in] pub_states The pubStates flag.
 *
 * @return    Indicates whether the unsubscription request is 
 *  		  successful. On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngUnsubActions(int pub_states);

/** @brief Publish a single action.
 *
 * This function attempts to publish a single action.
 *
 * @param[in] action_name The name of an action.
 * @param[in] action_json A JSON string which contains an action. 
 * @param[in] qos         The qos of the message. 
 * @param[in] callback    A pointer to a publish callback function. 
 *
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubAction(char* action_name, char* action_json, int qos, pub_callback *callback);

/** @brief Publish a few actions.
 *
 * This function attempts to publish a few actions.
 *
 * @param[in] actions_json A JSON string which contains actions. 
 * @param[in] qos          The qos of the message. 
 * @param[in] callback     A pointer to a publish callback function. 
 *
 * @return    Indicates whether the message is accepted for publication.
 *            On Success: EVRYTHNG_SUCCESS
 *            On Failure: EVRYTHNG_FAILURE
 */
evrythng_return_e EvrythngPubActions(char* actions_json, int qos, pub_callback *callback);

/** @brief Set Evrythng log level.
 *
 * This function attempts to change the Evrythng log level.
 *
 * @param[in] level  An Evrythng log level.
 */
void EvrythngSetLogLevel(int level);

#endif //_EVRYTHNG_H
