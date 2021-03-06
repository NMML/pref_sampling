### run simple preferential sampling models on bearded seal data
library(PrefSampling)
data(Data_for_ST_plot) #includes spatial objects associated w landscape
data(Bearded_effort)
data(AlaskaBeringData)  #from bass package on github/nmml
Effort=Bearded_effort

#create single Grid SpatialPolygonsDataFrame, averaging over covariate values
Grid.new=Data$Grid$y2012[[1]]
Days = c(6:12) #Apr 10-16
Grid.new@data=0*Grid.new@data
for(iday in Days)Grid.new@data=Grid.new@data+Data$Grid$y2012[[iday]]@data
Grid.new@data=Grid.new@data/length(Days)

#limit effort data to April 10-16
Which.incl = which(Effort$Mapping[,2]<8)
Mapping=Effort$Mapping[Which.incl,1]
Prop_sampled=Effort$Area.trans[Which.incl]
Prop_sampled[which(is.na(Prop_sampled))]=1.0
Count.data=Effort$Count.data[Which.incl,]

# Settings
n_test_obs = 40 # sample size for repeated subsample cross-validation training set
n_folds = 100 # number of training sets to test
n_cells=length(Grid.new)
n_samp = length(Mapping)
#SpatialScale = sqrt(n_cells)/5  # Range ~ 2*Scale
#SD_eta = SD_x = SD_delta = 1
#beta0 = 2
Use_REML = FALSE   # 
#Spatial_sim_model = c("GP_gaussian", "ICAR")[1]
Spatial_model = c("SPDE_GMRF", "ICAR")[1]
Alpha = 2  # Smoothness for GMRF, 1 or 2 (1 is faster)

# Model configurations
EM_set = c("fix_b","est_b")

set.seed(12345)

# massage into paper notation
s_i = Mapping
y_s = ifelse(1:n_cells %in% s_i, 1, 0)
x_s_z = cbind(Grid.new@data[,"ice_conc"],Grid.new@data[,"ice_conc"]^2,Grid.new@data[,"dist_edge"],Grid.new@data[,"depth"],Grid.new@data[,"depth"]^2,Grid.new@data[,"dist_land"])  
x_s_y = cbind(Grid.new@data[,"dist_mainland"])  
x_s_b = matrix(1,nrow=n_cells,ncol=3)  #design matrix for preferential sampling effect
Centroids=gCentroid(Grid.new,byid=TRUE)
loc_s=cbind(Centroids$x,Centroids$y)/25067.53 #standardize by making distance between neighboring cells = 1.0
loc_s[,1]=loc_s[,1]/mean(loc_s[,2])
loc_s[,2]=loc_s[,2]/mean(loc_s[,2])
colnames(loc_s)=c("x","y")
rownames(loc_s)=c(1:n_cells)
x_s_b[,2:3] = loc_s
c_i = Count.data[,"Count"]   #changed to binom for v5, 11/9
Count=rep(NA,prod(n_cells))
Count[s_i]=c_i
n_train_obs = n_samp-n_test_obs

mesh = inla.mesh.create( loc_s )
spde <- (inla.spde2.matern(mesh, alpha=1)$param.inla)[c("M0","M1","M2")]


Options_vec = c( 'Prior'=switch(Spatial_model,"ICAR"=1,"SPDE_GMRF"=0), 'Alpha'=Alpha, 'IncludeDelta'=1, 'IncludeEta'=1, 'OutputSE'=1,'bPrior'=0)

Pred_score = Pred_score2 = array(0,c(n_folds,3,3))  #holds cross validation results

for(ifold in 1:n_folds){
  Which_data = sample(c(1:n_samp),n_train_obs)
  #Which_test = c(1:n_samp)
  #Which_test = Which_test[-Which_data]
  c_i_train = c_i[Which_data]
  c_i_test = c_i[-Which_data]
  Prop_sampled_train = Prop_sampled[Which_data]
  Prop_sampled_test = Prop_sampled[-Which_data]
  s_i_train = Mapping[Which_data]
  s_i_test = Mapping[-Which_data]
  #y_s_train = ifelse(1:n_cells %in% s_i_train, 1, 0)
  y_s_train = y_s
  
  for(icov in 1:2){
    for(ib in 1:3){
      # Data
      Data = list("Options_vec"=Options_vec, "c_i"=c_i_train, "P_i"=Prop_sampled_train,"A_s"=1-Grid.new@data[,"land_cover"],"s_i"=s_i_train-1, "y_s"=y_s_train, "spde"=spde)
      if(icov==1)Data$X_sj=Data$X_sk=matrix(1,nrow=n_cells)
      if(icov>1){
        Data$X_sj=cbind(1,x_s_z)
        Data$X_sk=cbind(1,x_s_y)
      }   
      if(ib<3)Data$X_sb=matrix(1,nrow=n_cells)
      if(ib==3)Data$X_sb=cbind(x_s_b)
      
      # Parameters
      if( Options_vec['Prior']==0 ) etainput_s = deltainput_s = rep(0,mesh$n)
      if( Options_vec['Prior']==1 ) etainput_s = deltainput_s = rep(0,prod(grid_dim))
      #Params = list("beta_j"=rep(0,ncol(Data$X_sj)), "beta_k"=rep(0,ncol(Data$X_sk)), "b"=0, "logtau_z"=rep(0,2), "logkappa_z"=rep(0,2), "deltainput_s"=deltainput_s, "etainput_s"=etainput_s)
      Params = list("beta_j"=rep(0,ncol(Data$X_sj)), "beta_k"=rep(0,ncol(Data$X_sk)), "beta_b"=rep(0,ncol(Data$X_sb)), "logtau_z"=rep(0,2), "logkappa_z"=rep(0,2), "deltainput_s"=deltainput_s, "etainput_s"=etainput_s)
      
      # Random
      Random = c( "deltainput_s", "etainput_s" )
      if(Use_REML==TRUE) Random = c(Random,"beta_j","beta_k","beta_b")
      
      # Fix parameters
      Map = list()
      # Fix common spatial-scale
      Map[["logkappa_z"]] = factor( rep(1,length(Params[["logkappa_z"]])) )
      # Elminate intercept and marginal-SD if using ICAR model
      if( Options_vec['Prior']==1 ){
        Params[["logtau"]] = log(1)
        Map[["logtau"]] = factor(NA)
        Params[["beta_j"]] = log(1)
        Map[["beta_j"]] = factor(NA)
      }
      # Eliminate linkeage of density and sampling intensity
      if(ib==1){
        Map[["beta_b"]] = factor(rep(NA,length(Params[["beta_b"]])))
      }
      # don't estimate fixed effects for sampling model if no covariates are modeled
      #if(icov==1) Map[["beta_k"]] = factor(rep(NA,length(Params[["beta_k"]])))
      
      # Make object
      #compile( paste0(Version,".cpp") )
      #dyn.load( dynlib(Version) )
      Start_time = Sys.time()
      Obj = MakeADFun( data=Data, parameters=Params, random=Random, map=Map, silent=TRUE, DLL="PrefSampling")
      Obj$fn( Obj$par )
      
      # Run
      Lower = -50
      Upper = 50
      #Lower = -Inf
      #Upper=Inf
      Opt = nlminb( start=Obj$par, objective=Obj$fn, gradient=Obj$gr, lower=Lower, upper=Upper, control=list(trace=1, maxit=1000))         #
      
      Opt[["diagnostics"]] = data.frame( "Param"=names(Obj$par), "Lower"=-Inf, "Est"=Opt$par, "Upper"=Inf, "gradient"=Obj$gr(Opt$par) )
      Report = Obj$report()
      
      # Potentially fix random fields with zero sample or population variance
      if( any(Report$MargSD_z<0.001) ){
        cat("FIX initiated \n")
        Which = which(Report$MargSD_z<0.001)
        Map[["logtau_z"]] = factor( ifelse(1:2==Which,NA,1:2) )
        if(length(Which)==2){
          Map[["logkappa_z"]] = factor( c(NA,NA) )
        }
        if( any(Which==1) ){
          Map[["deltainput_s"]] = factor( rep(NA,length(Params[["deltainput_s"]])) )
          Params[["deltainput_s"]][] = 0
          Map[["beta_b"]] = factor(rep(NA,length(Params[["beta_b"]])))
          Params[["beta_b"]][] = 0
        }
        if( any(Which==2) ){
          Map[["etainput_s"]] = factor( rep(NA,length(Params[["etainput_s"]])) )
          Params[["etainput_s"]][] = 0
        }
        Data$Options_vec[Which+2] = 0
        # Re-run
        if( length(Which)!=2 ) Obj = MakeADFun( data=Data, parameters=Params, random=Random, map=Map, silent=TRUE,DLL="PrefSampling")
        if( length(Which)==2 ) Obj = MakeADFun( data=Data, parameters=Params, random=NULL, map=Map, silent=TRUE,DLL="PrefSampling")
        Opt = nlminb( start=Obj$par, objective=Obj$fn, gradient=Obj$gr, lower=Lower, upper=Upper, control=list(trace=1, maxit=1000))         #
        Opt[["diagnostics"]] = data.frame( "Param"=names(Obj$par), "Lower"=-Inf, "Est"=Opt$par, "Upper"=Inf, "gradient"=Obj$gr(Opt$par) )
      }
      
      # SD
      #Report = Obj$report()
      SD=sdreport(Obj,bias.correct=TRUE)
      Pred_lambda=SD$unbiased$value[which(names(SD$unbiased$value)=="Z_s")]
      Pred_lambda2=Pred_lambda
      Pred_lambda2=Pred_lambda*(Pred_lambda>0) #round estimates < 0 to 0
      Pred_score[ifold,icov,ib]=sum((c_i_test-Pred_lambda[s_i_test]*Prop_sampled_test)^2)
      #Pred_score2[ifold,icov,ib]=sum(dpois(c_i_test,Pred_lambda2[s_i_test]*Prop_sampled_test,log=TRUE))
    } 
  }
}


Pred_score = Pred_score[,1:2,]