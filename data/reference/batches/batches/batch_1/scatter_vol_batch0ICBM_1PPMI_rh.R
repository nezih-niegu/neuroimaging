scatters_vol_rh <- function(region) {
  
  library(tidyverse)
  library(openxlsx)
  
  #importing ages and sex
  T_1.5 <- read.csv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/PPMI_T1_controls_1.5T_9_10_2020.csv")
  T_3 <- read.csv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/PPMI_T1_controls_3T_9_10_2020.csv")
  batch0 <- read.xlsx("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/MRI_subjects_processed_data2.xlsx",'Sheet1')
  
  #rh volumes of batch 0
  batch0_rh <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/rhaparc_ICBM.txt"))
  batch0_rh$rh.aparc.volume <- substr(batch0_rh$rh.aparc.volume,61,63)
  colnames(batch0_rh)[1] <- "Num"
  colnames(batch0_rh) <- str_replace_all(colnames(batch0_rh),"-","_")
  colnames(batch0_rh) <- str_replace_all(colnames(batch0_rh),"3","thi")
  colnames(batch0_rh) <- str_replace_all(colnames(batch0_rh),"4","four")
  colnames(batch0_rh) <- str_replace_all(colnames(batch0_rh),"5","fif")
  batch0_withage <- merge(batch0_rh[, c("Num",region)],
                          batch0[, c("Num", "Age")])
  #p <- ggplot(batch0_withage, aes(x=Age,y=`Left_Lateral_Ventricle`))
  #p + geom_point()
  
  #rh volumes of batch 1 folder 1
  folder1_rh <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/folder_1/rhaparc_vol_2020-09-25_1732.txt"))
  folder1_rh$rh.aparc.volume <- substr(folder1_rh$rh.aparc.volume,6,9)
  colnames(folder1_rh)[1] <- "Subject"
  colnames(folder1_rh) <- str_replace_all(colnames(folder1_rh),"-","_")
  colnames(folder1_rh) <- str_replace_all(colnames(folder1_rh),"3","thi")
  colnames(folder1_rh) <- str_replace_all(colnames(folder1_rh),"4","four")
  colnames(folder1_rh) <- str_replace_all(colnames(folder1_rh),"5","fif")
  T_combined <- rbind(T_1.5,T_3)
  folder1_withage <- merge(folder1_rh[, c("Subject",region)],
                           T_combined[, c("Subject", "Age")])
  
  #rh volumes of batch 1 folder 2
  folder2_rh <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/folder_2/rhaparc_vol_2020-09-26_1111.txt"))
  folder2_rh$rh.aparc.volume <- substr(folder2_rh$rh.aparc.volume,6,9)
  colnames(folder2_rh)[1] <- "Subject"
  colnames(folder2_rh) <- str_replace_all(colnames(folder2_rh),"-","_")
  colnames(folder2_rh) <- str_replace_all(colnames(folder2_rh),"3","thi")
  colnames(folder2_rh) <- str_replace_all(colnames(folder2_rh),"4","four")
  colnames(folder2_rh) <- str_replace_all(colnames(folder2_rh),"5","fif")
  folder2_withage <- merge(folder2_rh[, c("Subject",region)],
                           T_combined[, c("Subject", "Age")])
  
  
  region_volumes <- rbind(batch0_withage[,2:3],folder1_withage[,2:3],folder2_withage[,2:3])
  p <- ggplot(region_volumes, aes_string(x="Age",y=region))
  p <- p + geom_point()
  print(p)
  ggsave(p, file=paste('C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/plots_vol_rh/',region, ".jpeg", sep=''), scale=2)
}

batch0_rh <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/rhaparc_ICBM.txt"))
batch0_rh$rh.aparc.volume <- substr(batch0_rh$rh.aparc.volume,61,63)
colnames(batch0_rh)[1] <- "Num"
colnames(batch0_rh) <- str_replace_all(colnames(batch0_rh),"-","_")
colnames(batch0_rh) <- str_replace_all(colnames(batch0_rh),"3","thi")
colnames(batch0_rh) <- str_replace_all(colnames(batch0_rh),"4","four")
colnames(batch0_rh) <- str_replace_all(colnames(batch0_rh),"5","fif")
regions <- colnames(batch0_rh)

for (i in regions[2:37]) {
  scatters_vol_rh(i)
}
