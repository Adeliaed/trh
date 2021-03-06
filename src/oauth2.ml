open GapiUtils.Infix
open GapiLens.Infix
open GapiMonad
open GapiMonad.SessionM.Infix

let scope = [ GapiDriveV2Service.Scope.drive ]

(* Gapi request wrapper *)
let do_request go =
  let update_state session =
    let context = Context.get_ctx () in
    let state = context |. Context.state_lens in
    let access_token =
      session |. GapiConversation.Session.auth
      |. GapiConversation.Session.oauth2 |. GapiLens.option_get
      |. GapiConversation.Session.oauth2_token
    in
    if state.State.last_access_token <> access_token then
      context
      |> (Context.state_lens |-- State.last_access_token) ^= access_token
      |> Context.save_state_from_context
  in
  let interact session =
    let ((_, session') as result) = go session in
    update_state session';
    result
  in
  let rec try_request n =
    try
      let context = Context.get_ctx () in
      let state = context |. Context.state_lens in
      let config = context.Context.gapi_config in
      let curl_state = context.Context.curl_state in
      let auth_context =
        GapiConversation.Session.OAuth2
          {
            GapiConversation.Session.oauth2_token =
              state.State.last_access_token;
            refresh_token = state.State.refresh_token;
          }
      in
      GapiConversation.with_session ~auth_context config curl_state interact
    with
    | Failure message as e ->
        let check_offline () =
          ExtString.String.exists message "CURLE_COULDNT_RESOLVE_HOST"
          || ExtString.String.exists message "CURLE_COULDNT_RESOLVE_PROXY"
        in
        let is_temporary_curl_error () =
          ExtString.String.exists message "CURLE_OPERATION_TIMEOUTED"
          || ExtString.String.exists message "CURLE_COULDNT_CONNECT"
          || ExtString.String.exists message "CURLE_SSL_CONNECT_ERROR"
          || ExtString.String.exists message "CURLE_SEND_ERROR"
          || ExtString.String.exists message "CURLE_RECV_ERROR"
        in
        Utils.log_with_header "Error during request: %s\n%!" message;
        if is_temporary_curl_error () && n < !Utils.max_retries then (
          let n' = n + 1 in
          Utils.log_with_header "Retrying (%d/%d)\n%!" n' !Utils.max_retries;
          GapiUtils.wait_exponential_backoff n;
          (* Retry on timeout *)
          try_request n')
        else if check_offline () then (
          Utils.log_with_header "Offline\n%!";
          raise e)
        else (
          Utils.log_with_header "Giving up\n%!";
          raise e)
    | GapiRequest.Unauthorized _ | GapiRequest.RefreshTokenFailed _ ->
        if n > 0 then
          failwith "Cannot access resource: Refreshing token was not enough";
        GaeProxy.refresh_access_token ();
        (* Retry with refreshed token *)
        try_request (n + 1)
    | Utils.Temporary_error as e ->
        if n < !Utils.max_retries then (
          let n' = n + 1 in
          Utils.log_with_header "Retrying (%d/%d)\n%!" n' !Utils.max_retries;
          GapiUtils.wait_exponential_backoff n;
          (* Retry on timeout *)
          try_request n')
        else (
          Utils.log_with_header "Giving up\n%!";
          raise e)
    | GapiService.ServiceError (_, e) ->
        Utils.log_with_header "ServiceError\n%!";
        let message =
          e |> GapiError.RequestError.to_data_model
          |> GapiJson.data_model_to_json |> Yojson.Safe.to_string
        in
        failwith message
  in
  try_request 0

(* Get access token using the installed apps flow or print authorization URL
 * if headless mode is on or get access token using the device flow if device
 * mode is on. *)
let get_access_token headless device browser =
  let context = Context.get_ctx () in
  let config_lens = context |. Context.config_lens in
  let client_id = config_lens |. Config.client_id in
  let client_secret = config_lens |. Config.client_secret in
  let verification_code = config_lens |. Config.verification_code in
  let redirect_uri =
    match config_lens |. Config.redirect_uri with
    | "" when config_lens |. Config.oauth2_loopback ->
        Printf.sprintf "http://127.0.0.1:%d/oauth2callback"
          (config_lens |. Config.oauth2_loopback_port)
    | "" -> "urn:ietf:wg:oauth:2.0:oob"
    | uri -> uri
  in
  let scope =
    match config_lens |. Config.scope with "" -> scope | s -> [ s ]
  in
  let get_access_token =
    if device then (
      GapiOAuth2Devices.request_code ~client_id ~scope
      >>= fun authorization_code ->
      Printf.printf
        "Please, open the following URL in a web browser: %s\n\
         and enter the following code: %s\n\
         %!"
        authorization_code.GapiOAuth2Devices.AuthorizationCode.verification_url
        authorization_code.GapiOAuth2Devices.AuthorizationCode.user_code;
      GapiOAuth2Devices.poll_authorization_server ~client_id ~client_secret
        ~authorization_code
      >>= fun access_token -> SessionM.return access_token)
    else
      let code =
        let start_context_polling () =
          let get_code_from_context () =
            let context = Context.get_ctx () in
            context |. Context.verification_code
          in
          let rec loop n =
            if n = 60 then
              failwith "Cannot retrieve verification code: Timeout expired";
            let code = get_code_from_context () in
            if code <> "" then (
              Printf.printf "Verification code retrieved correctly: %s.\n%!"
                code;
              code)
            else (
              Thread.delay 5.0;
              loop (succ n))
          in
          loop 0
        in
        if verification_code = "" then (
          let url =
            GapiOAuth2.authorization_code_url ~redirect_uri ~scope
              ~response_type:"code" client_id
          in
          if headless then
            Printf.printf
              "Please, open the following URL in a web browser: %s\n%!" url
          else (
            if config_lens |. Config.oauth2_loopback then
              LoopbackServer.start (config_lens |. Config.oauth2_loopback_port);
            Utils.start_browser browser url);
          if (not headless) && config_lens |. Config.oauth2_loopback then
            start_context_polling ()
          else (
            Printf.printf "Please enter the verification code: %!";
            input_line stdin))
        else verification_code
      in
      GapiOAuth2.get_access_token ~client_id ~client_secret ~code ~redirect_uri
      >>= fun access_token -> SessionM.return access_token
  in
  try
    let response, _ = do_request get_access_token in
    Printf.printf "Access token retrieved correctly.\n%!";
    let { GapiAuthResponse.OAuth2.access_token; refresh_token; _ } =
      response |. GapiAuthResponse.oauth2_access_token |. GapiLens.option_get
    in
    let now = GapiDate.now () in
    let current_state = context |. Context.state_lens in
    context
    |> Context.state_lens
       ^= {
            current_state with
            State.auth_request_date = now;
            refresh_token;
            last_access_token = access_token;
            access_token_date = now;
          }
    |> Context.save_state_from_context
  with e ->
    prerr_endline "Cannot retrieve auth tokens.";
    Printexc.to_string e |> prerr_endline;
    exit 1
