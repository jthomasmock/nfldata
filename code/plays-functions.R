########## HELPER FUNCTIONS ##########

# report progress to console
report <- function(msg)
{
  print(paste0(Sys.time(),": ",msg))
}

# report error
report_error <- function(msg)
{
  print(paste0(Sys.time(),": ERROR: ",msg))
  return(NULL)
}

# look for text in names of columns of data frame
grep_col <- function(x,df=plays)
{
  return(colnames(df)[grepl(x,colnames(df))])
}

# fix inconsistent data types
fix_inconsistent_data_types <- function(p)
{
  p <- p %>% 
    mutate(game_id=as.character(game_id),
           play_id=as.numeric(play_id),
           time=as.character(time),
           down=as.numeric(down),
           blocked_player_id=as.character(blocked_player_id),
           fumble_recovery_2_yards=as.numeric(fumble_recovery_2_yards),
           fumble_recovery_2_player_id=as.character(fumble_recovery_2_player_id),
           forced_fumble_player_2_player_id=as.character(forced_fumble_player_2_player_id))
  return(p)
}

# fix team abbreviations
## by default this just makes every team have the same abbreviation all season
## use old_to_new=TRUE to make teams that have moved use the new abbreviation in the past
fix_team_abbreviations <- function(p,old_to_new=FALSE)
{
  for (col in grep_col("team",df))
  {
    x <- p %>% pull(col)
    if (typeof(x) == "character")
    {
      p[,col] <- case_when(
        x == "JAC" ~ "JAX",
        x == "LA" ~ "LAR",
        x == "SD" & old_to_new ~ "LAC",
        x == "STL" & old_to_new ~ "LAR",
        TRUE ~ x)
    }
  }
  return(p)
}

########## FUNCTIONS TO APPLY ADDITIONAL DATA ##########

# game data
apply_game_data <- function(p)
{
  if (!("alt_game_id" %in% colnames(p)))  # already included, don't reapply
  {
    report("Applying game data")    
    games <- read_csv("https://raw.githubusercontent.com/leesharpe/nfldata/master/data/games.csv")
    games <- games %>%
      mutate(game_id=as.character(game_id))
    p <- p %>% 
      fix_inconsistent_data_types() %>% 
      inner_join(games,by=c("game_id"="game_id","away_team"="away_team","home_team"="home_team"))
  }
  return(p)
}

# mutations from Ben Baldwin (and some code from Keegan Abdoo)
## taken from https://gist.github.com/guga31bb/5634562c5a2a7b1e9961ac9b6c568701
apply_baldwin_mutations <- function(p)
{
  report("Applying Ben Baldwin mutations")
  p <- p %>% 
    mutate(
      # identify passes and rushes
      ## note this treats qb scrambles as passes since a pass was called
      pass=ifelse(str_detect(desc,"(pass)|(sacked)|(scramble)"),1,0),
      rush=ifelse(str_detect(desc,"(left end)|(left tackle)|(left guard)|(up the middle)|(right guard)|(right tackle)|(right end)") & pass == 0,1,0),
      # plays are defined as successful when EPA is positive
      success=ifelse(is.na(epa),NA,ifelse(epa>0,1,0)),
      # fix player name fields so they aren't NA on penalty p
      passer_player_name=ifelse(play_type == "no_play" & pass == 1, 
                                str_extract(desc,"(?<=\\s)[A-Z][a-z]*\\.\\s?[A-Z][A-z]+(\\s(I{2,3})|(IV))?(?=\\s((pass)|(sack)|(scramble)))"),
                                passer_player_name),
      receiver_player_name=ifelse(play_type == "no_play" & str_detect(desc, "pass"), 
                                  str_extract(desc,"(?<=to\\s)[A-Z][a-z]*\\.\\s?[A-Z][A-z]+(\\s(I{2,3})|(IV))?"),
                                  receiver_player_name),
      rusher_player_name=ifelse(play_type == "no_play" & rush == 1, 
                                str_extract(desc,"(?<=\\s)[A-Z][a-z]*\\.\\s?[A-Z][A-z]+(\\s(I{2,3})|(IV))?(?=\\s((left end)|(left tackle)|(left guard)|(up the middle)|(right guard)|(right tackle)|(right end)))"),
                                rusher_player_name),
      # this is shorthand so "name" is the QB (if pass) or runner (if run)
      name=ifelse(!is.na(passer_player_name),passer_player_name,rusher_player_name),
      # set yards_gained to be NA on penalties rather then 0
      yards_gained=ifelse(play_type == "no_play",NA,yards_gained),
      # easy filter: play is 1 if a "normal" play (including penalties), or 0 otherwise
      play=ifelse(!is.na(epa) & !is.na(posteam) & play_type %in% c("no_play","pass","run"),1,0))
  return(p)
}

# add series data
## series = 
##  starts at 1, each new first down increments, numbers shared across both teams
##  NA: kickoffs, extra point/two point conversion attempts, non-plays, no posteam
##  Note: Also is broken for 2013 Week 12 & 13 games due to nflscrapR data issues
## series_success =
##  1: scored touchdown, gained enough yards for first down
##  0: punt, interception, fumble lost, turnover on downs, 4th down FG attempt or punt
##  NA: series is NA, series contains QB spike/kneel, half ended with none of above
apply_series_data <- function(p)
{
  #report("Applying series and series success")
  broken_games <- unique(p$game_id[is.na(p$yards_gained) & p$play_type != "no_play"])
  p <- p %>% mutate(series=NA,series_success=0)
  
  # initialize loop trackers
  p$series[min(which(p$play_type != "kickoff"))] <- 1
  p$series_success[1:(min(which(p$play_type != "kickoff"))-1)] <- NA
  series <- 1
  lb <- 1
  
  # play loop
  for (r in (min(which(p$play_type != "kickoff"))+1):nrow(p))
  {
    #report(paste0("Series: ",series))
    #report(paste0("== Processing play_id ",p$play_id[r]," (row ",r,", lb == ",lb,") ==="))
    #report(paste0(p$down[r]," & ",p$ydstogo[r],": ",p$desc[r]))
    
    # progress #report
    if (r %% 25000 == 0) #report(paste("Series Data:",r,"of",nrow(p),"plays"))
    
    # skip broken games
    if (p$game_id[r] %in% broken_games)
    {
      lb <- lb + 1
      next
    }
    
    # if posteam is not defined, mark as a non-series and skip
    if (is.na(p$posteam[r]))
    {
      p$series[r] <- NA
      p$series_success[r] <- NA
      lb <- lb + 1
      next
    }
    
    # game has changed
    if (p$game_id[r] != p$game_id[r-lb]) 
    {
      #report("New game!")
      if (p$yards_gained[r-lb] >= p$ydstogo[r-lb])
      {
        p$series_success[p$game_id == p$game_id[r-lb] & p$series == series] <- 1
      } else if (any(p$play_type[p$game_id == p$game_id[r] & p$series == series]
                     %in% c("qb_kneel","qb_spike"))) {
        p$series_success[p$game_id == p$game_id[r] & p$series == series] <- NA        
      } else if (p$down[r-lb] == 4) {
        p$series_success[p$game_id == p$game_id[r-lb] & p$series == series] <- 0
      } else {
        p$series_success[p$game_id == p$game_id[r-lb] & p$series == series] <- NA
      }
      series <- 1
    # beginning of 2nd half or overtime
    } else if (p$qtr[r] != p$qtr[r-lb] && (p$qtr[r] == 3 || p$qtr[r] >= 5)) {
      #report("New half/overtime!")
      if (p$yards_gained[r-lb] >= p$ydstogo[r-lb])
      {
        p$series_success[p$game_id == p$game_id[r] & p$series == series] <- 1
      } else if (any(p$play_type[p$game_id == p$game_id[r] & p$series == series]
                     %in% c("qb_kneel","qb_spike"))) {
        p$series_success[p$game_id == p$game_id[r] & p$series == series] <- NA
      } else if (p$down[r-lb] == 4) {
        p$series_success[p$game_id == p$game_id[r-lb] & p$series == series] <- 0        
      } else {
        p$series_success[p$game_id == p$game_id[r] & p$series == series] <- NA
      }
      series <- series + 1
    # or drive has changed  
    } else if (p$drive[r] != p$drive[r-lb]) {
      #report("New drive!")
      if (p$yards_gained[r-lb] >= p$ydstogo[r-lb])
      {
        p$series_success[p$game_id == p$game_id[r] & p$series == series] <- 1
      } else if (any(p$play_type[p$game_id == p$game_id[r] & p$series == series]
                   %in% c("qb_kneel","qb_spike"))) {
        p$series_success[p$game_id == p$game_id[r] & p$series == series] <- NA
      }
      series <- series + 1
    # first down or NA down with last play having enough yards or defensive penalty
    } else if ((is.na(p$down[r]) || p$down[r] == 1) &&
              ((!is.na(p$yards_gained[r-lb]) && p$yards_gained[r-lb] >= p$ydstogo[r-lb])
               || any(p$first_down_penalty[(r-lb):(r-1)] == 1,na.rm=TRUE))) {
      #report("First down!")
      if (p$play_type[r-lb] != "kickoff" ||
          any(p$first_down_penalty[(r-lb):(r-1)] == 1,na.rm=TRUE))
      {
        p$series_success[p$game_id == p$game_id[r] & p$series == series] <- 1
      }
      series <- series + 1
    }
    
    # mark series for kickoffs as NA
    if (!is.na(p$play_type[r]) && p$play_type[r] == "kickoff")
    {
      #report("Kickoff!")
      p$series_success[r] <- NA
      series <- series - 1  # otherwise it would advance 2, want to advance 1
    # mark series for extra point or two point conversions attempts as NA
    } else if ((!is.na(p$play_type[r]) && p$play_type[r] == "extra_point") ||
               (!is.na(p$two_point_attempt[r]) && p$two_point_attempt[r] == 1)) {
      #report("XP/2PC attempt!")
      p$series_success[r] <- NA
      series <- series - 1  # otherwise it would advance 2, want to advance 1
    # mark series for all other p
    } else {
      #report(paste0("Noting series #",series))
      p$series[r] <- series
    }
    
    # if this is a real play, reset lookback to 1, otherwise increment it
    ## the looback defines the "previous" play
    ## we want to skip this for p that don't actually affect series data
    if (is.na(p$play_type[r]) || p$play_type[r] == "no_play" ||
        p$play_type[r] == "extra_point" || is.na(p$posteam[r]) ||
        (!is.na(p$two_point_attempt[r]) && p$two_point_attempt[r] == 1))
    {
      lb <- lb + 1
      #report(paste0("Incrementing lb to ",lb))
    } else {
      lb <- 1
      #report(paste0("Reseting lb to 1"))
    }
    
  }
  
  # handle final series in the data
  lb <- 0
  while(is.na(p$play_type[nrow(p)-lb]) || p$play_type[nrow(p)-lb] == "no_play")
  {
    lb <- lb + 1
  }
  if (p$yards_gained[nrow(p)-lb] >= p$ydstogo[nrow(p)-lb])
  {
    p$series_success[p$game_id == p$game_id[nrow(p)-lb] & p$series == series] <- 1
  } else if (any(p$play_type[p$game_id == p$game_id[r] & p$series == series]
                 %in% c("qb_kneel","qb_spike"))) {
    p$series_success[p$game_id == p$game_id[r] & p$series == series] <- NA    
  } else if (p$down[nrow(p)-lb] == 4) {
    p$series_success[p$game_id == p$game_id[nrow(p)-lb] & p$series == series] <- 0
  } else {
    p$series_success[p$game_id == p$game_id[nrow(p)] & p$series == series] <- NA
  }
  
  #report(paste("Series Data Complete!"))
  return(p)
}
